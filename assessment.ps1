param(
    [string]$ApiKey = "ak_72fa9004e6bdfe98b2aa907d95965eb72cbd191fb5decc7f",
    [switch]$Submit,
    [switch]$UseLocalAnalysis,
    [switch]$SubmitExistingResults
)

$BaseUrl = "https://assessment.ksensetech.com/api"
$OutputPath = Join-Path $PSScriptRoot "assessment_results.json"
$AnalysisPath = Join-Path $PSScriptRoot "assessment_analysis.json"
$Limit = 20
$MaxRetries = 6
$MaxPages = 50
$HighRiskThreshold = 4
$Headers = @{
    "x-api-key" = $ApiKey
    "Accept"    = "application/json"
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [hashtable] -and $Object.ContainsKey($Name)) {
        return $Object[$Name]
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Convert-ToFloatOrNull {
    param([object]$Value)

    if ($null -eq $Value -or $Value -is [bool]) {
        return $null
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [double]$Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $number = 0.0
    if ([double]::TryParse($text.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }

    return $null
}

function Convert-ToIntOrNull {
    param([object]$Value)

    $number = Convert-ToFloatOrNull $Value
    if ($null -eq $number) {
        return $null
    }

    if ($number -ne [math]::Floor($number)) {
        return $null
    }

    return [int]$number
}

function Get-RetryDelaySeconds {
    param(
        [int]$Attempt,
        [string]$RetryAfter
    )

    $delay = 0.0
    if (-not [string]::IsNullOrWhiteSpace($RetryAfter)) {
        if ([double]::TryParse($RetryAfter, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$delay)) {
            return [math]::Max($delay, 0.0)
        }
    }

    $baseDelay = [math]::Min([math]::Pow(2, $Attempt - 1), 8)
    $jitter = Get-Random -Minimum 0.0 -Maximum 0.25
    return [double]$baseDelay + [double]$jitter
}

function Invoke-AssessmentRequest {
    param(
        [ValidateSet("GET", "POST")]
        [string]$Method,
        [string]$Path,
        [hashtable]$Query,
        [object]$Body
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $url = "$BaseUrl$Path"
        if ($Query) {
            $pairs = foreach ($entry in $Query.GetEnumerator() | Sort-Object Name) {
                "{0}={1}" -f [uri]::EscapeDataString([string]$entry.Key), [uri]::EscapeDataString([string]$entry.Value)
            }
            $url = "{0}?{1}" -f $url, ($pairs -join "&")
        }

        try {
            if ($Method -eq "GET") {
                return Invoke-RestMethod -Method Get -Uri $url -Headers $Headers -TimeoutSec 20
            }

            $requestHeaders = @{
                "x-api-key"    = $ApiKey
                "Accept"       = "application/json"
                "Content-Type" = "application/json"
            }
            $jsonBody = $Body | ConvertTo-Json -Depth 8 -Compress
            return Invoke-RestMethod -Method Post -Uri $url -Headers $requestHeaders -Body $jsonBody -TimeoutSec 20
        }
        catch {
            $statusCode = $null
            $retryAfter = $null
            $bodyText = $null
            $response = $_.Exception.Response

            if ($null -ne $response) {
                try {
                    $statusCode = [int]$response.StatusCode
                }
                catch {
                }

                try {
                    $retryAfter = $response.Headers["Retry-After"]
                }
                catch {
                }

                try {
                    $stream = $response.GetResponseStream()
                    if ($null -ne $stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $bodyText = $reader.ReadToEnd()
                        $reader.Dispose()
                        $stream.Dispose()
                    }
                }
                catch {
                }
            }

            if ($statusCode -in 429, 500, 502, 503, 504 -and $attempt -lt $MaxRetries) {
                $delaySeconds = Get-RetryDelaySeconds -Attempt $attempt -RetryAfter $retryAfter
                Start-Sleep -Milliseconds ([int]($delaySeconds * 1000))
                continue
            }

            if ($null -ne $statusCode) {
                throw "HTTP $statusCode for $Method $url. $bodyText"
            }

            if ($attempt -lt $MaxRetries) {
                $delaySeconds = Get-RetryDelaySeconds -Attempt $attempt -RetryAfter $null
                Start-Sleep -Milliseconds ([int]($delaySeconds * 1000))
                continue
            }

            throw
        }
    }

    throw "Request failed after $MaxRetries attempts: $Method $Path"
}

function Get-PatientsFromResponse {
    param([object]$Response)

    $data = Get-PropertyValue -Object $Response -Name "data"
    if ($data -is [array]) {
        return @($data)
    }

    if ($null -ne $data -and $data -isnot [string]) {
        $inner = Get-PropertyValue -Object $data -Name "patients"
        if ($inner -is [array]) {
            return @($inner)
        }
    }

    if ($Response -is [array]) {
        return @($Response)
    }

    return @()
}

function Test-HasNextPage {
    param(
        [object]$Pagination,
        [int]$Page,
        [int]$Added,
        [int]$PageLimit
    )

    $hasNext = Get-PropertyValue -Object $Pagination -Name "hasNext"
    if ($hasNext -is [bool]) {
        return $hasNext
    }

    $totalPages = Convert-ToIntOrNull (Get-PropertyValue -Object $Pagination -Name "totalPages")
    if ($null -ne $totalPages) {
        return $Page -lt $totalPages
    }

    $total = Convert-ToIntOrNull (Get-PropertyValue -Object $Pagination -Name "total")
    if ($null -ne $total) {
        return ($Page * $PageLimit) -lt $total
    }

    return $Added -ge $PageLimit
}

function Get-BloodPressureScore {
    param([object]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or -not $text.Contains("/")) {
        return @{
            Score   = 0
            Invalid = $true
        }
    }

    $parts = $text.Split("/", 2)
    $systolic = Convert-ToIntOrNull $parts[0]
    $diastolic = Convert-ToIntOrNull $parts[1]

    if ($null -eq $systolic -or $null -eq $diastolic) {
        return @{
            Score   = 0
            Invalid = $true
        }
    }

    $systolicScore = 0
    if ($systolic -ge 140) {
        $systolicScore = 3
    }
    elseif ($systolic -ge 130) {
        $systolicScore = 2
    }
    elseif ($systolic -ge 120) {
        $systolicScore = 1
    }

    $diastolicScore = 0
    if ($diastolic -ge 90) {
        $diastolicScore = 3
    }
    elseif ($diastolic -ge 80) {
        $diastolicScore = 2
    }

    return @{
        Score   = [math]::Max($systolicScore, $diastolicScore)
        Invalid = $false
    }
}

function Get-TemperatureScore {
    param([object]$Value)

    $temperature = Convert-ToFloatOrNull $Value
    if ($null -eq $temperature) {
        return @{
            Score   = 0
            Invalid = $true
            Fever   = $false
        }
    }

    if ($temperature -ge 101.0) {
        return @{
            Score   = 2
            Invalid = $false
            Fever   = $true
        }
    }

    if ($temperature -ge 99.6) {
        return @{
            Score   = 1
            Invalid = $false
            Fever   = $true
        }
    }

    return @{
        Score   = 0
        Invalid = $false
        Fever   = $false
    }
}

function Get-AgeScore {
    param([object]$Value)

    $age = Convert-ToFloatOrNull $Value
    if ($null -eq $age) {
        return @{
            Score   = 0
            Invalid = $true
        }
    }

    if ($age -lt 40) {
        return @{
            Score   = 0
            Invalid = $false
        }
    }

    if ($age -gt 65) {
        return @{
            Score   = 2
            Invalid = $false
        }
    }

    return @{
        Score   = 1
        Invalid = $false
    }
}

function Get-AllPatients {
    $patients = New-Object System.Collections.Generic.List[object]
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $page = 1
    $emptyPageRetries = 0

    while ($page -le $MaxPages) {
        $response = Invoke-AssessmentRequest -Method "GET" -Path "/patients" -Query @{ page = $page; limit = $Limit }
        $pageItems = Get-PatientsFromResponse $response
        if ($pageItems.Count -eq 0) {
            if ($page -eq 1 -and $emptyPageRetries -lt 2) {
                $emptyPageRetries++
                Start-Sleep -Milliseconds 500
                continue
            }
            break
        }
        $emptyPageRetries = 0

        $added = 0
        foreach ($patient in $pageItems) {
            $patientId = [string](Get-PropertyValue -Object $patient -Name "patient_id")
            if ([string]::IsNullOrWhiteSpace($patientId)) {
                $uniqueKey = $patient | ConvertTo-Json -Depth 8 -Compress
            }
            else {
                $uniqueKey = $patientId.Trim()
            }

            if ($seen.Add($uniqueKey)) {
                $patients.Add($patient)
                $added++
            }
        }

        $pagination = Get-PropertyValue -Object $response -Name "pagination"
        $reportedHasNext = Test-HasNextPage -Pagination $pagination -Page $page -Added $added -PageLimit $Limit
        $totalPages = Convert-ToIntOrNull (Get-PropertyValue -Object $pagination -Name "totalPages")

        if (($null -ne $totalPages -and $page -ge $totalPages) -or (-not $reportedHasNext -and $pageItems.Count -lt $Limit)) {
            break
        }

        $page++
    }

    return $patients
}

function Get-AssessmentPayload {
    param([System.Collections.Generic.List[object]]$Patients)

    $highRiskPatients = New-Object System.Collections.Generic.List[string]
    $feverPatients = New-Object System.Collections.Generic.List[string]
    $dataQualityIssues = New-Object System.Collections.Generic.List[string]
    $analysisRows = New-Object System.Collections.Generic.List[object]

    foreach ($patient in $Patients) {
        $patientId = [string](Get-PropertyValue -Object $patient -Name "patient_id")
        if ([string]::IsNullOrWhiteSpace($patientId)) {
            continue
        }

        $patientId = $patientId.Trim()
        $bp = Get-BloodPressureScore (Get-PropertyValue -Object $patient -Name "blood_pressure")
        $temp = Get-TemperatureScore (Get-PropertyValue -Object $patient -Name "temperature")
        $age = Get-AgeScore (Get-PropertyValue -Object $patient -Name "age")
        $totalRisk = $bp.Score + $temp.Score + $age.Score

        if ($totalRisk -ge $HighRiskThreshold) {
            $highRiskPatients.Add($patientId)
        }

        if ($temp.Fever) {
            $feverPatients.Add($patientId)
        }

        if ($bp.Invalid -or $temp.Invalid -or $age.Invalid) {
            $dataQualityIssues.Add($patientId)
        }

        $analysisRows.Add([ordered]@{
            patient_id = $patientId
            age = Get-PropertyValue -Object $patient -Name "age"
            temperature = Get-PropertyValue -Object $patient -Name "temperature"
            blood_pressure = Get-PropertyValue -Object $patient -Name "blood_pressure"
            bp_score = $bp.Score
            temp_score = $temp.Score
            age_score = $age.Score
            total_risk = $totalRisk
            bp_invalid = $bp.Invalid
            temp_invalid = $temp.Invalid
            age_invalid = $age.Invalid
            has_fever = $temp.Fever
        })
    }

    return [ordered]@{
        payload = [ordered]@{
            high_risk_patients = @($highRiskPatients | Sort-Object -Unique)
            fever_patients = @($feverPatients | Sort-Object -Unique)
            data_quality_issues = @($dataQualityIssues | Sort-Object -Unique)
        }
        analysis = @($analysisRows | Sort-Object patient_id)
    }
}

if ($SubmitExistingResults) {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "Saved results file not found at $OutputPath."
    }

    $savedPayload = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
    Write-Host "Loaded existing payload from $OutputPath"
    Write-Host ($savedPayload | ConvertTo-Json -Depth 6)

    $submissionResponse = Invoke-AssessmentRequest -Method "POST" -Path "/submit-assessment" -Body $savedPayload
    Write-Host "Submission response:"
    $submissionResponse | ConvertTo-Json -Depth 10
    exit 0
}

if ($UseLocalAnalysis) {
    if (-not (Test-Path -LiteralPath $AnalysisPath)) {
        throw "Local analysis file not found at $AnalysisPath."
    }

    $analysisRows = Get-Content -LiteralPath $AnalysisPath -Raw | ConvertFrom-Json
    $patients = @($analysisRows | ForEach-Object {
        [pscustomobject]@{
            patient_id = $_.patient_id
            age = $_.age
            temperature = $_.temperature
            blood_pressure = $_.blood_pressure
        }
    })
}
else {
    $patients = Get-AllPatients
}

if ($patients.Count -eq 0) {
    throw "No patient data was returned by the API."
}

$assessment = Get-AssessmentPayload -Patients $patients
$payload = $assessment.payload
$payloadJson = $payload | ConvertTo-Json -Depth 6
$analysisJson = $assessment.analysis | ConvertTo-Json -Depth 6
Set-Content -LiteralPath $OutputPath -Value $payloadJson -Encoding UTF8
Set-Content -LiteralPath $AnalysisPath -Value $analysisJson -Encoding UTF8

Write-Host "Fetched $($patients.Count) unique patients"
Write-Host $payloadJson
Write-Host "Saved alert lists to $OutputPath"
Write-Host "Saved patient analysis to $AnalysisPath"

if ($Submit) {
    $submissionResponse = Invoke-AssessmentRequest -Method "POST" -Path "/submit-assessment" -Body $payload
    Write-Host "Submission response:"
    $submissionResponse | ConvertTo-Json -Depth 10
}
