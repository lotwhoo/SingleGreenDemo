#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
require_text "README.md" "377/377"
require_text "README.md" "62/62"
require_text "docs/RELEASE_CHECKLIST.md" "377/377"
require_text "NOTICE.md" "BSD/PATENTS/AUTHORS acknowledgements"
require_text "NOTICE.md" "spl_sqrt_floor/spl_sqrt_floor.h"
authoritative=(README.md Packages/README.md docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md docs/RELEASE_CHECKLIST.md)
if rg -n 'production detector factory remains nil|生产检测器 factory 仍为空|生产 detector factory 仍为空|生产 detector.*尚未批准|approval box.*unchecked|未引入 WebRTC|真实麦克风/VAD/服务和当前真机功能仍未验收|mic-fix signed device build/codesign/install passed, but launch was blocked|real VAD/mic/ASR/provider/UI acceptance remains unverified|No real VAD, microphone, ASR, LLM, Search, GitHub CI, backend, or rollback evidence is claimed' "${authoritative[@]/#/$repository_root/}"; then
  echo "error: stale pre-integration VAD claim found in authoritative documentation" >&2
  exit 1
fi
echo "VAD documentation state check passed (approved integration; current evidence 377/377 and 62/62)."
