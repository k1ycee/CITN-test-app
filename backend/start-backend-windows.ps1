param(
    [string]$PythonCommand = "",
    [string]$Port = "3000",
    [string]$GeminiApiKey = "",
    [switch]$SkipInstall,
    [switch]$NoRun
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Resolve-PythonCommand {
    param([string]$RequestedCommand)

    $candidates = @()
    if ($RequestedCommand) {
        $candidates += $RequestedCommand
    }
    $candidates += "py -3"
    $candidates += "python"

    foreach ($candidate in $candidates) {
        try {
            $versionOutput = Invoke-Expression "$candidate --version" 2>&1
            if ($LASTEXITCODE -eq 0) {
                return $candidate
            }
        } catch {
        }
    }

    throw "Python 3 was not found. Install Python 3.11+ and ensure 'py' or 'python' is available in PATH."
}

function Invoke-Python {
    param(
        [string]$PythonExe,
        [string]$Arguments
    )

    Invoke-Expression "$PythonExe $Arguments"
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed: $PythonExe $Arguments"
    }
}

$python = Resolve-PythonCommand -RequestedCommand $PythonCommand
$venvDir = Join-Path $scriptDir ".venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$envFile = Join-Path $scriptDir ".env"
$envExampleFile = Join-Path $scriptDir ".env.example"

Write-Step "Using Python command: $python"

if (-not (Test-Path $venvPython)) {
    Write-Step "Creating virtual environment"
    Invoke-Python -PythonExe $python -Arguments "-m venv `"$venvDir`""
}

if (-not (Test-Path $venvPython)) {
    throw "Virtual environment creation did not produce $venvPython"
}

if (-not $SkipInstall) {
    Write-Step "Upgrading pip"
    & $venvPython -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upgrade pip"
    }

    Write-Step "Installing backend dependencies"
    & $venvPython -m pip install -r (Join-Path $scriptDir "requirements.txt")
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install backend dependencies"
    }
}

if (-not (Test-Path $envFile)) {
    Write-Step "Creating .env file"

    if (Test-Path $envExampleFile) {
        Copy-Item $envExampleFile $envFile
    } else {
        @(
            "GEMINI_API_KEY="
            "GEMINI_MODEL=gemini-3-flash-preview"
            "DATABASE_URL=sqlite:///quiz.db"
            "PORT=3000"
        ) | Set-Content -Path $envFile
    }
}

if ($GeminiApiKey) {
    Write-Step "Updating GEMINI_API_KEY in .env"
    $envLines = Get-Content $envFile
    $updated = $false
    $newLines = foreach ($line in $envLines) {
        if ($line -match "^GEMINI_API_KEY=") {
            $updated = $true
            "GEMINI_API_KEY=$GeminiApiKey"
        } else {
            $line
        }
    }
    if (-not $updated) {
        $newLines += "GEMINI_API_KEY=$GeminiApiKey"
    }
    $newLines | Set-Content -Path $envFile
}

$env:PORT = $Port

if ($NoRun) {
    Write-Host ""
    Write-Host "Backend is prepared." -ForegroundColor Green
    Write-Host "Run it with:" -ForegroundColor Green
    Write-Host "  .\.venv\Scripts\python.exe .\app.py"
    exit 0
}

Write-Host ""
Write-Host "Backend starting at http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop." -ForegroundColor Green
Write-Host ""

& $venvPython (Join-Path $scriptDir "app.py")
