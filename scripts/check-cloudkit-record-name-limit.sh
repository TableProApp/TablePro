#!/usr/bin/env bash
set -euo pipefail

# CloudKit record name limit gate.
#
# SyncRecordName.maximumLength hard-codes what CKRecord.ID(recordName:) accepts. The value is not
# in a header and CloudKit raises an Objective-C exception rather than returning nil, so a wrong
# number is a crash rather than a rejected write, and the crash lands seconds later on an unrelated
# thread (#2575). This measures the real framework and compares it against the constant.
#
# Usage: scripts/check-cloudkit-record-name-limit.sh

cd "$(dirname "$0")/.."

SOURCE="Packages/TableProCore/Sources/TableProSyncTransport/SyncRecordType.swift"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [[ -d "$candidate" ]]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi

declared=$(sed -n 's/.*maximumLength = \([0-9][0-9]*\).*/\1/p' "$SOURCE" | head -1)
if [[ -z "$declared" ]]; then
    echo "FAIL: could not read maximumLength from $SOURCE" >&2
    exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

cat > "$workdir/probe.m" <<'OBJC'
#import <CloudKit/CloudKit.h>
#import <Foundation/Foundation.h>

static BOOL accepts(NSUInteger length) {
    NSString *name = [@"" stringByPaddingToLength:length withString:@"a" startingAtIndex:0];
    CKRecordZoneID *zone = [[CKRecordZoneID alloc] initWithZoneName:@"probe"
                                                          ownerName:CKCurrentUserDefaultName];
    @try {
        (void)[[CKRecordID alloc] initWithRecordName:name zoneID:zone];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

int main(void) {
    @autoreleasepool {
        NSUInteger low = 1;
        NSUInteger high = 4096;
        if (accepts(high)) {
            printf("%lu\n", (unsigned long)high);
            return 0;
        }
        while (low + 1 < high) {
            NSUInteger mid = (low + high) / 2;
            if (accepts(mid)) {
                low = mid;
            } else {
                high = mid;
            }
        }
        printf("%lu\n", (unsigned long)low);
    }
    return 0;
}
OBJC

clang -fobjc-arc -framework CloudKit -framework Foundation \
    -o "$workdir/probe" "$workdir/probe.m"

measured=$("$workdir/probe")

echo "declared SyncRecordName.maximumLength: $declared"
echo "measured CKRecord.ID limit:            $measured"

if [[ "$declared" != "$measured" ]]; then
    echo "FAIL: CloudKit accepts $measured UTF-16 code units, the source declares $declared." >&2
    echo "Update SyncRecordName.maximumLength in $SOURCE." >&2
    exit 1
fi

echo "PASS"
