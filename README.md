# DemoMed Assessment

This repo now follows the scoring shown on the assessment page exactly:

- Blood pressure: normal `0`, elevated `1`, stage 1 `2`, stage 2 `3`
- Temperature: normal `0`, low fever `1`, high fever `2`
- Age: under `40` is `0`, `40-65` is `1`, over `65` is `2`
- High-risk patients: total score `>= 4`

Run the assessment client from this folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\assessment.ps1
```

Submit the computed alert lists:

```powershell
powershell -ExecutionPolicy Bypass -File .\assessment.ps1 -Submit
```

Submit a previously saved payload without re-fetching patients:

```powershell
powershell -ExecutionPolicy Bypass -File .\assessment.ps1 -SubmitExistingResults
```

The PowerShell script uses the provided API key by default, fetches all patient pages with retry logic, computes the required alert lists, and writes the payload to `assessment_results.json`.
