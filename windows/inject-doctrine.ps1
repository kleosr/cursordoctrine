# inject-doctrine.ps1 - Cursor sessionStart injection.
#
# Emits {"additional_context": "<doctrine + USER-RULES>"} as PURE-ASCII JSON.
#
# Why pure ASCII: the doctrine contains multi-byte UTF-8 characters (em dash,
# section sign, <=, arrows). Written as UTF-8, their continuation bytes
# (0x80-0x9F) get decoded by Cursor's JSON reader as C1 control characters ->
# "Bad control character in string literal in JSON at position N". Escaping every
# non-ASCII char to \uXXXX makes the output byte-identical under EVERY encoding,
# so it cannot be mangled; JSON.parse turns § back into the real char. We
# also write the bytes straight to stdout to bypass [Console]::OutputEncoding.
#
# Fail open: missing files or any error -> "{}" (valid, empty). Never block or
# crash session start.

$ErrorActionPreference = 'SilentlyContinue'

# Drain stdin (Cursor sends session metadata) so the pipe never blocks.
$null = [Console]::In.ReadToEnd()

function Write-StdoutAscii([string]$s) {
    # Write exact ASCII bytes to stdout, immune to whatever [Console]::OutputEncoding is.
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($s)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

try {
    $doctrinePath = Join-Path $PSScriptRoot 'doctrine.md'
    $context = ''
    if (Test-Path -LiteralPath $doctrinePath) {
        $context = (Get-Content -Raw -LiteralPath $doctrinePath).Trim()
    }

    if (-not $context) { Write-StdoutAscii '{}'; exit 0 }

    $json = @{ additional_context = $context } | ConvertTo-Json -Compress

    # Escape every non-ASCII (and any stray control) char to \uXXXX -> pure ASCII.
    # ConvertTo-Json's structural chars and \n / \" escapes are ASCII and pass through.
    $sb = [System.Text.StringBuilder]::new($json.Length + 64)
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 32 -or $code -gt 126) { [void]$sb.AppendFormat('\u{0:x4}', $code) }
        else { [void]$sb.Append($ch) }
    }
    Write-StdoutAscii $sb.ToString()
}
catch {
    Write-StdoutAscii '{}'
}

exit 0
