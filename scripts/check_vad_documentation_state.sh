#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if command -v rg >/dev/null 2>&1; then
  search_lines() { rg -n -- "$@"; }
  search_lines_ignore_case() { rg -n -i -- "$@"; }
  search_matches() { rg -o -- "$@"; }
else
  search_lines() { grep -nE -- "$@"; }
  search_lines_ignore_case() { grep -nEi -- "$@"; }
  search_matches() { grep -Eo -- "$@"; }
fi

require_text() {
  local file=$1 marker=$2
  if ! grep -Fq "$marker" "$repository_root/$file"; then
    echo "error: $file is missing required VAD documentation marker: $marker" >&2
    exit 1
  fi
}
require_text "docs/tasks/2026-08-28-webrtc-vad-approval-adr.md" "状态：已获用户批准并完成实现"
require_text "docs/tasks/2026-08-28-webrtc-vad-approval-adr.md" "1e7f4c3c39e1aacaf8884452f80cd82749b1f8f1"
require_text "docs/tasks/2026-08-28-webrtc-vad-approval-adr.md" "11 upstream C + 1 local compatibility C + 12 upstream headers"
require_text "AGENTS.md" "ten library modules (20 snapshots total)"
require_text "docs/AGENT_WORKFLOW.md" "ten modules × two arm64 platforms = 20 snapshots"
require_text "docs/tasks/2026-08-28-m7-pr2-lifecycle-correctness.md" "owns one ContinuousClock-backed, injectable monotonic frame-liveness watchdog"
require_text "NOTICE.md" "BSD/PATENTS/AUTHORS acknowledgements"
require_text "NOTICE.md" "spl_sqrt_floor/spl_sqrt_floor.h"
authoritative=(README.md Packages/README.md docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md docs/RELEASE_CHECKLIST.md)
if search_lines 'production detector factory remains nil|生产检测器 factory 仍为空|生产 detector factory 仍为空|生产 detector.*尚未批准|approval box.*unchecked|未引入 WebRTC|真实麦克风/VAD/服务和当前真机功能仍未验收|mic-fix signed device build/codesign/install passed, but launch was blocked|real VAD/mic/ASR/provider/UI acceptance remains unverified|No real VAD, microphone, ASR, LLM, Search, GitHub CI, backend, or rollback evidence is claimed' "${authoritative[@]/#/$repository_root/}"; then
  echo "error: stale pre-integration VAD claim found in authoritative documentation" >&2
  exit 1
fi

require_section_text() {
  local section_name=$1 section=$2 marker=$3
  if ! grep -Fq "$marker" <<<"$section"; then
    echo "error: $section_name is missing required M7 PR5 evidence marker: $marker" >&2
    exit 1
  fi
}

retry_xcresult='/private/tmp/SingleGreenDemo-M7-PR5-AppTests-Retry/Logs/Test/Test-SingleGreenDemo-2026.08.28_19-46-03-+0800.xcresult'
current_release=$(sed -n '/^## M7 PR5 mechanical decomposition (current local evidence/,/^## Version and source/p' "$repository_root/docs/RELEASE_CHECKLIST.md")
current_arch=$(sed -n '/^### M7 PR5 Mechanical decomposition/,/^### M1 已实现的契约/p' "$repository_root/docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md")
current_readme=$(sed -n '/^## 验证边界/,/^## 关联文档/p' "$repository_root/README.md")

require_section_text "README PR5 validation section" "$current_readme" "**438/438**"
require_section_text "README PR5 validation section" "$current_readme" "**55/55**"
require_section_text "README PR5 validation section" "$current_readme" "**340/340**"
require_section_text "README PR5 validation section" "$current_readme" "$retry_xcresult"
require_text "README.md" "**17×20=340/340**"
require_text "README.md" "16 个 API snapshots byte-identical"

require_section_text "release checklist PR5 section" "$current_release" "**438/438**"
require_section_text "release checklist PR5 section" "$current_release" "**55/55**"
require_section_text "release checklist PR5 section" "$current_release" "**17 × 20 = 340/340**"
require_section_text "release checklist PR5 section" "$current_release" "16 byte-identical API snapshots"
require_section_text "release checklist PR5 section" "$current_release" "architecture negative fixtures remain **11**"
require_section_text "release checklist PR5 section" "$current_release" "$retry_xcresult"

require_section_text "architecture report PR5 section" "$current_arch" "**438/438**"
require_section_text "architecture report PR5 section" "$current_arch" "**55/55**"
require_section_text "architecture report PR5 section" "$current_arch" "**17×20=340/340**"
require_section_text "architecture report PR5 section" "$current_arch" "16 个 API snapshots byte-identical"
require_section_text "architecture report PR5 section" "$current_arch" "架构负例 11 个"
require_section_text "architecture report PR5 section" "$current_arch" "$retry_xcresult"

if printf '%s\n%s\n%s\n' "$current_readme" "$current_release" "$current_arch" | \
    search_lines 'seven modules|七个模块|14 snapshots|14 个|390/390|414/414|62/62|10 个负例|10 negative'; then
  echo "error: stale historical count found in an authoritative M7 PR5 evidence section" >&2
  exit 1
fi

while IFS= read -r claim; do
  if ! grep -Eqi 'historical|superseded|历史|已由 PR5|此前|兼容标记' <<<"$claim"; then
    echo "error: PR3+PR4 evidence is still labeled current/latest without a historical or superseded qualifier: $claim" >&2
    exit 1
  fi
done < <(search_lines_ignore_case \
  '(PR3[[:space:]]*\+[[:space:]]*PR4.*(current|latest|当前|最新)|(current|latest|当前|最新).*PR3[[:space:]]*\+[[:space:]]*PR4)' \
  "${authoritative[@]/#/$repository_root/}" || true)

validate_concurrent_result_claim() {
  local claim=$1 old_concurrent_result normalized
  old_concurrent_result=$(search_matches '/private/tmp/SingleGreenDemo-M7-PR5-AppTests(\.xcresult|/Logs/Test/[^`[:space:]]+\.xcresult)' <<<"$claim" | head -n 1)
  [[ -n "$old_concurrent_result" ]] || return 1

  normalized=${claim//non-authoritative/}
  normalized=${normalized//non authoritative/}
  normalized=${normalized//not authoritative/}
  normalized=${normalized//非权威/}
  if grep -Eqi '(^|[^[:alpha:]])(current|isolated|authoritative)([^[:alpha:]]|$)|当前|隔离|权威' <<<"$normalized"; then
    return 1
  fi
  grep -Eqi 'concurrent|并发' <<<"$claim" && grep -Eqi 'timing[ -]warning' <<<"$claim"
}

invalid_concurrent_samples=(
  'The concurrent timing-warning run /private/tmp/SingleGreenDemo-M7-PR5-AppTests.xcresult is authoritative and current.'
  'The concurrent timing-warning run /private/tmp/SingleGreenDemo-M7-PR5-AppTests.xcresult, which is authoritative and current.'
  'The concurrent timing-warning run /private/tmp/SingleGreenDemo-M7-PR5-AppTests.xcresult；这是当前权威结果。'
)
for invalid_concurrent_sample in "${invalid_concurrent_samples[@]}"; do
  if validate_concurrent_result_claim "$invalid_concurrent_sample"; then
    echo "error: concurrent-result guard self-test accepted a current/authoritative label after the old xcresult path: $invalid_concurrent_sample" >&2
    exit 1
  fi
done
valid_concurrent_sample='The non-authoritative concurrent timing-warning run /private/tmp/SingleGreenDemo-M7-PR5-AppTests.xcresult is retained for historical comparison.'
if ! validate_concurrent_result_claim "$valid_concurrent_sample"; then
  echo "error: concurrent-result guard self-test rejected explicit non-authoritative warning wording" >&2
  exit 1
fi

while IFS= read -r claim; do
  if ! validate_concurrent_result_claim "$claim"; then
    echo "error: the concurrent PR5 xcresult must be non-authoritative concurrent timing-warning evidence: $claim" >&2
    exit 1
  fi
done < <(search_lines \
  '/private/tmp/SingleGreenDemo-M7-PR5-AppTests(\.xcresult|/Logs/Test/[^`[:space:]]+\.xcresult)' \
  "${authoritative[@]/#/$repository_root/}" || true)

echo "VAD documentation state check passed (approved integration; authoritative M7 PR5 evidence 438/438, 55/55, 340/340, 16 snapshots, and 11 negative fixtures)."
