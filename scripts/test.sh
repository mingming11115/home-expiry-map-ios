#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swiftc="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
test_dir="$project_dir/build-native/logic-tests"
mkdir -p "$test_dir"
compile=("$swiftc" -swift-version 5 -sdk "$sdk" -module-cache-path "$project_dir/.module-cache")
app="$project_dir/ExpiryMap"
tests="$project_dir/Tests"

"${compile[@]}" "$app/NativeModel.swift" "$app/NativeStore.swift" \
  "$tests/NativeStoreTests.swift" -o "$test_dir/store-tests"
"${compile[@]}" "$app/LabelParser.swift" "$tests/LabelParserTests.swift" \
  -o "$test_dir/label-tests"
"${compile[@]}" -D REMINDER_SCHEDULER_TESTS "$app/NativeModel.swift" \
  "$app/NativeStore.swift" "$app/ReminderPlan.swift" "$app/ReminderScheduler.swift" \
  "$tests/ReminderSchedulerTests.swift" -o "$test_dir/reminder-tests"
"$test_dir/label-tests"
for timezone in Asia/Shanghai America/Los_Angeles; do
  TZ="$timezone" "$test_dir/store-tests"
  TZ="$timezone" "$test_dir/reminder-tests"
done
