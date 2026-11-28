# WINDOWS POWERSHELL 5.1
# ==============================================================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Keep Windows PowerShell 5.1's existing console behavior. PowerShell 7 can
# inherit a legacy Windows console code page (for example CP1251), which
# renders UTF-8 box-drawing characters as mojibake. Align the console and
# native-pipeline encodings on UTF-8 before any UI is written.
if ($PSVersionTable.PSVersion.Major -ge 7 -and $env:OS -eq 'Windows_NT') {
    try { & "$env:SystemRoot\System32\chcp.com" 65001 > $null } catch {}
    $MiraUtf8 = [System.Text.UTF8Encoding]::new($false)
    try { [Console]::InputEncoding = $MiraUtf8 } catch {}
    try { [Console]::OutputEncoding = $MiraUtf8 } catch {}
    $OutputEncoding = $MiraUtf8
} else {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}

# ==============================================================================
# CONFIGURATION & PERSONA INJECTION
# ==============================================================================
# ==============================================================================
# USER CONFIGURATION — all runtime defaults are centralized here
# ==============================================================================
# Answer provider and model
$MIRA_DEFAULT_PROVIDER = 'antigravity'       # 'antigravity', 'gemini', 'openai', or 'groq'; no automatic provider switching
$MIRA_DEFAULT_MODEL = 'gemini-3.1-flash-lite'
$MIRA_DEFAULT_EFFORT = 'high'                # Shared fallback for every provider: low, medium, high
# Provider overrides ($null inherits the shared/default effort).
$MIRA_OPENAI_EFFORT = $null                  # none, minimal, low, medium, high, xhigh, max
$MIRA_OPENAI_LUNA_EFFORT = $null            # Optional model-specific override; $null inherits .effort
$MIRA_GEMINI_EFFORT = $null                  # low, medium, high
$MIRA_ANTIGRAVITY_EFFORT = $null             # low, medium, high
$MIRA_GROQ_EFFORT = 'low'                    # Keep short chat turns economical; override with low/medium/high as needed
$MIRA_SEARCH_MODEL = 'gemini-3.1-flash-lite' # Dedicated Antigravity OAuth research model for Gemini API web_search

# Generation defaults ($null means: let the selected model use its own default)
$MIRA_TEMPERATURE = $null                   # 0.0–2.0 where supported
$MIRA_TOP_P = $null
$MIRA_TOP_K = $null
$MIRA_MAX_OUTPUT_TOKENS = $null
$MIRA_CANDIDATE_COUNT = $null
$MIRA_PRESENCE_PENALTY = $null
$MIRA_FREQUENCY_PENALTY = $null
$MIRA_SEED = $null
$MIRA_RESPONSE_MIME_TYPE = $null            # e.g. 'text/plain' or 'application/json'
$MIRA_STOP_SEQUENCES = $null                # e.g. @('END')

# On-demand Gemini speech playback
$MIRA_TTS_MODEL = 'gemini-3.8-flash-tts'
$MIRA_TTS_VOICE = 'Sulafat'

# Runtime behavior
$MIRA_DEFAULT_PERMISSION = 'ask'            # 'ask' or 'autopilot'; ASK prompt defaults to Yes
$MIRA_DEFAULT_GROUNDING = $true              # Global master switch for all Google Search grounding
$MIRA_ENABLE_AGENTIC_WEB_SEARCH = $true       # Allow Gemini API models to call web_search through Antigravity OAuth
$MIRA_DEFAULT_VERBOSE = $false                # Show provider thought summaries only when enabled with .verbose
$MIRA_DEFAULT_STREAMING_MODE = 'line'           # 'line', 'delta', or 'off'; line matches agy-open default

# OpenAI settings. Luna uses Responses API; other OpenAI models use Chat Completions.
# Token limit maps to max_output_tokens (Responses) or max_completion_tokens (Chat Completions).
$MIRA_OPENAI_DEFAULT_MODEL = 'gpt-6-luna'
$MIRA_OPENAI_MAX_COMPLETION_TOKENS = $null
$MIRA_OPENAI_TEMPERATURE = $null                 # Chat Completions only
$MIRA_OPENAI_RESPONSE_FORMAT = $null              # Shared setting; converted to each endpoint's format

# Groq uses its OpenAI-compatible Chat Completions endpoint.
$MIRA_GROQ_MAX_COMPLETION_TOKENS = $null
$MIRA_GROQ_TEMPERATURE = $null
$MIRA_GROQ_TOP_P = $null
$MIRA_GROQ_RESPONSE_FORMAT = $null
# GPT-6 Luna uses OpenAI-hosted web_search directly in the Responses API.
# Antigravity chat sends native googleSearch to the selected model. Gemini API models
# may call web_search, delegated to the dedicated Antigravity OAuth research model.
$MIRA_DEFAULT_CACHED_CONTENT = $null
$MIRA_DEFAULT_SYSTEM_PROMPT = @"
You are a concise, accurate assistant. Use tools only when the request requires local Windows access or live information. The local command tool accepts PowerShell and can launch CMD, Python, or installed utilities; elevation always requires Windows UAC. Inspect before modifying, preserve user data, obey ASK/AUTOPILOT permissions, and verify actions before claiming success.
"@

# Safety defaults (kept at the script's existing values; editable here)
$MIRA_DEFAULT_SAFETY_THRESHOLD = 'BLOCK_NONE'

# Limits and console behavior
$MIRA_MAX_TOOL_ROUNDS = 32
$MIRA_MAX_POWERSHELL_OUTPUT_CHARS = 20000
$MIRA_MAX_COMMAND_OUTPUT_CHARS = 20000
$MIRA_MAX_SEARCH_OUTPUT_CHARS = 24000
$MIRA_MAX_HISTORY = 500
$MIRA_POWERSHELL_OUTPUT_WIDTH = 240
$MIRA_SPINNER_INTERVAL_MS = 150
$MIRA_CONSOLE_TITLE = 'GEMMA CLI'
try { $Host.UI.RawUI.WindowTitle = $MIRA_CONSOLE_TITLE } catch {}

# API KEY ROTATION — explicit candidates only. No environment-variable discovery.
# Each entry is one account/key candidate; order is the rotation order.
$script:GeminiApiKeys = @(
    $env:GEMINI_API_KEY  # API 1 — primary account
    $env:GEMINI_APIJ     # API 2
) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
    ForEach-Object { ([string]$_).Trim() }
$script:MiraGeminiApiKeyIndex = 0

$script:OpenAIApiKeys = @(
    $env:OPENAI_APIJ
    $env:OPENAI_API_OLD
    $env:OPENAI_API_KEY
) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
    ForEach-Object { ([string]$_).Trim() }
$script:MiraOpenAIApiKeyIndex = 0

$script:GroqApiKeys = @(
    $env:GROQ_APIJ
    $env:GROQ_API_KEY
) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
    ForEach-Object { ([string]$_).Trim() }
$script:MiraGroqApiKeyIndex = 0
$script:GroqKeyRotationErrorCodes = @(
    'invalid_api_key'
    'authentication_error'
    'insufficient_quota'
    'billing_hard_limit_reached'
)

# Move to the next configured OpenAI key for these key/account-specific failures.
# Organization TPM/usage limits are shared across that organization's keys.
# Project-scoped limits may differ by project; rotation only helps if the next
# candidate has a separate applicable limit and available capacity.
$script:OpenAIKeyRotationErrorCodes = @(
    'invalid_api_key'
    'incorrect_api_key'
    'authentication_error'
    'insufficient_permissions'
    'permission_denied'
    'rate_limit_exceeded'
    'rate_limit_error'
    'insufficient_quota'
    'credit_balance_exhausted'
    'organization_usage_limit_exceeded'
    'organization_spend_limit_exceeded'
    'project_spend_limit_exceeded'
    'billing_hard_limit_reached'
)

# Session-local provider usage. These counters are updated from actual responses;
# .usage is passive and never sends a probe request.
$script:MiraUsageStats = @{
    StartedAt = Get-Date
    Requests = 0
    SuccessfulRequests = 0
    FailedRequests = 0
    HttpAttempts = 0
    InputTokens = 0
    OutputTokens = 0
    ByProvider = @{}
    LastRequest = $null
    ProviderRateLimits = @{}
    OpenAIRateLimits = @{}
}

if ($script:GeminiApiKeys.Count -eq 0 -and
    -not (Test-Path -LiteralPath (Join-Path (Join-Path $HOME '.gemini\antigravity-cli') 'antigravity-oauth-token'))) {
    Write-Host "No Gemini API key or Antigravity OAuth token found. Configure a candidate in the Gemini API key list." -ForegroundColor Yellow
}

$MODEL = $MIRA_DEFAULT_MODEL
$script:ActiveSystemPromptName = 'default'
function Get-GemmaSystemPromptText {
    param([Parameter(Mandatory = $true)][string]$BasePrompt)

    $text = $BasePrompt.Trim()
    if ($script:CommandMode) {
        $text += @"

COMMAND GENERATION MODE:
Return only the best ready-to-run Windows command or short command chain for the user's request.
Choose the appropriate shell or runtime: CMD, PowerShell, Python, or an installed utility. Do not assume PowerShell is always the best choice.
Do not execute commands, call tools, inspect the machine, or claim anything was executed.
Prefer concise commands, quote paths correctly, and use the syntax of the selected shell/runtime.
For locating a file and showing it in Explorer, choose the most direct command for the selected shell.
Output no Markdown fences, no explanation, and no alternatives unless one command cannot safely express the task.
"@
    }
    return $text
}

$SystemInstruction = @{
    parts = @(
        @{ text = (Get-GemmaSystemPromptText -BasePrompt $MIRA_DEFAULT_SYSTEM_PROMPT) }
    )
}















# ==============================================================================
# GEMINI API REQUEST STATE / OPTIONAL REQUEST FIELDS
# Request payload configuration.
# ==============================================================================
$GeminiTools = $null
$GeminiToolConfig = $null
$GeminiCachedContent = $MIRA_DEFAULT_CACHED_CONTENT
$GeminiGenerationConfig = @{}
foreach ($setting in @(
    @{ Name = 'temperature'; Value = $MIRA_TEMPERATURE },
    @{ Name = 'topP'; Value = $MIRA_TOP_P },
    @{ Name = 'topK'; Value = $MIRA_TOP_K },
    @{ Name = 'maxOutputTokens'; Value = $MIRA_MAX_OUTPUT_TOKENS },
    @{ Name = 'candidateCount'; Value = $MIRA_CANDIDATE_COUNT },
    @{ Name = 'presencePenalty'; Value = $MIRA_PRESENCE_PENALTY },
    @{ Name = 'frequencyPenalty'; Value = $MIRA_FREQUENCY_PENALTY },
    @{ Name = 'seed'; Value = $MIRA_SEED },
    @{ Name = 'responseMimeType'; Value = $MIRA_RESPONSE_MIME_TYPE },
    @{ Name = 'stopSequences'; Value = $MIRA_STOP_SEQUENCES }
)) {
    if ($null -ne $setting.Value) {
        $GeminiGenerationConfig[$setting.Name] = $setting.Value
    }
}
if ($GeminiGenerationConfig.Count -eq 0) { $GeminiGenerationConfig = $null }
$GeminiSafetySettings = @(
        @{
            category  = "HARM_CATEGORY_SEXUALLY_EXPLICIT"
            threshold = $MIRA_DEFAULT_SAFETY_THRESHOLD
        },
        @{
            category  = "HARM_CATEGORY_HATE_SPEECH"
            threshold = "BLOCK_NONE"
        },
        @{
            category  = "HARM_CATEGORY_HARASSMENT"
            threshold = "BLOCK_NONE"
        },
        @{
            category  = "HARM_CATEGORY_DANGEROUS_CONTENT"
            threshold = "BLOCK_NONE"
        }
    )
$script:GoogleSearchGrounding = [bool]$MIRA_DEFAULT_GROUNDING
$script:AgenticWebSearchEnabled = [bool]$MIRA_ENABLE_AGENTIC_WEB_SEARCH
$script:VerboseOutput = [bool]$MIRA_DEFAULT_VERBOSE
$script:StreamingMode = ([string]$MIRA_DEFAULT_STREAMING_MODE).Trim().ToLowerInvariant()
if ($script:StreamingMode -notin @('off','line','delta')) { $script:StreamingMode = 'line' }
$script:Provider = $MIRA_DEFAULT_PROVIDER
$script:Effort = $MIRA_DEFAULT_EFFORT
$script:ExecutionPermission = $MIRA_DEFAULT_PERMISSION
$script:InApprovedPowerShellTool = $false
$script:AntigravityProject = $null
$script:AntigravityWebSearchModelIds = $null
$script:AntigravityCapabilityProbeAttempted = $false
