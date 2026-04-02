# DemoMed Assessment

This repo now follows the scoring shown on the assessment page exactly:

- Blood pressure: normal `0`, elevated `1`, stage 1 `2`, stage 2 `3`
- Temperature: normal `0`, low fever `1`, high fever `2`
- Age: under `40` is `0`, `40-65` is `1`, over `65` is `2`
- High-risk patients: total score `>= 4`

## API Key

The scripts do not store the API key in source control. They can read `DEMOMED_API_KEY`
from a local `.env` file, from your shell environment, or from a passed argument.

Create a local `.env` file in this folder:

```dotenv
DEMOMED_API_KEY=your-api-key-here
```

Or set the key as an environment variable before running:

```powershell
$env:DEMOMED_API_KEY="your-api-key-here"
```

You can also pass the key directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\assessment.ps1 -ApiKey "your-api-key-here"
```

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

The PowerShell script fetches all patient pages with retry logic, computes the required alert lists, and writes the payload to `assessment_results.json`.

## Security Note

The API key is loaded from a local `.env` file and is not intended to be committed to source control. The repository includes `.env.example` for local setup and `.gitignore` rules to keep local secrets out of tracked files.
