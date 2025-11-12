#!/bin/bash

# Test script for merge logic changes
# Tests that:
# 1. New entries with empty fields are added
# 2. Existing entries preserve values when new values are empty
# 3. Existing entries update when new values are non-empty

set -euo pipefail

echo "Testing merge logic..."

# Create temp directory for test
test_dir=$(mktemp -d)
trap "rm -rf $test_dir" EXIT

# Test 1: Adding new entry with empty publishUri
echo "Test 1: Add new entry with empty publishUri"
cat > "$test_dir/effective.csv" << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/existing,main,https://github.com/org/existing,hash123,https://artifactory.com/existing.jar
EOF

cat > "$test_dir/repos-lock.csv" << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/new-repo,main,https://github.com/org/new-repo,,
EOF

./merge-repos-csv.sh "$test_dir/effective.csv" "$test_dir/output1.csv" "$test_dir/repos-lock.csv"
echo "Output:"
cat "$test_dir/output1.csv"
echo ""

# Verify new entry was added even with empty publishUri
if grep -q "org/new-repo" "$test_dir/output1.csv"; then
    echo "✅ Test 1 PASSED: New entry with empty publishUri was added"
else
    echo "❌ Test 1 FAILED: New entry with empty publishUri was not added"
fi
echo "---"

# Test 2: Preserve existing publishUri when new value is empty
echo "Test 2: Preserve existing publishUri when new value is empty"
cat > "$test_dir/effective2.csv" << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/repo1,main,https://github.com/org/repo1,oldhash,https://artifactory.com/old.jar
EOF

cat > "$test_dir/repos-lock2.csv" << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/repo1,main,https://github.com/org/repo1,newhash,
EOF

./merge-repos-csv.sh "$test_dir/effective2.csv" "$test_dir/output2.csv" "$test_dir/repos-lock2.csv"
echo "Output:"
cat "$test_dir/output2.csv"
echo ""

# Verify publishUri was preserved (not overwritten with empty)
if grep -q "https://artifactory.com/old.jar" "$test_dir/output2.csv"; then
    echo "✅ Test 2 PASSED: Existing publishUri preserved when new is empty"
else
    echo "❌ Test 2 FAILED: Existing publishUri was overwritten with empty"
fi
echo "---"

# Test 3: Update when new values are non-empty
echo "Test 3: Update when new values are non-empty"
cat > "$test_dir/effective3.csv" << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/repo2,main,https://github.com/org/repo2,oldhash,https://artifactory.com/old.jar
EOF

cat > "$test_dir/repos-lock3.csv" << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/repo2,main,https://github.com/org/repo2,newhash,https://artifactory.com/new.jar
EOF

./merge-repos-csv.sh "$test_dir/effective3.csv" "$test_dir/output3.csv" "$test_dir/repos-lock3.csv"
echo "Output:"
cat "$test_dir/output3.csv"
echo ""

# Verify both fields were updated
if grep -q "newhash" "$test_dir/output3.csv" && grep -q "https://artifactory.com/new.jar" "$test_dir/output3.csv"; then
    echo "✅ Test 3 PASSED: Fields updated when new values are non-empty"
else
    echo "❌ Test 3 FAILED: Fields not properly updated"
fi
echo "---"

# Test 4: Mixed scenario - multiple repos with different conditions
echo "Test 4: Mixed scenario with multiple repositories"
cat > "$test_dir/effective4.csv" << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/repo1,main,https://github.com/org/repo1,hash1,https://artifactory.com/repo1.jar
github.com,org/repo2,main,https://github.com/org/repo2,hash2,
EOF

cat > "$test_dir/repos-lock4.csv" << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/repo1,main,https://github.com/org/repo1,newhash1,
github.com,org/repo2,main,https://github.com/org/repo2,newhash2,https://artifactory.com/repo2-new.jar
github.com,org/repo3,main,https://github.com/org/repo3,,
github.com,org/repo4,main,https://github.com/org/repo4,hash4,https://artifactory.com/repo4.jar
EOF

./merge-repos-csv.sh "$test_dir/effective4.csv" "$test_dir/output4.csv" "$test_dir/repos-lock4.csv"
echo "Output:"
cat "$test_dir/output4.csv"
echo ""

# Verify all conditions
line_count=$(wc -l < "$test_dir/output4.csv")
has_repo1_old_uri=$(grep -c "org/repo1.*https://artifactory.com/repo1.jar" "$test_dir/output4.csv" || true)
has_repo2_new_uri=$(grep -c "org/repo2.*https://artifactory.com/repo2-new.jar" "$test_dir/output4.csv" || true)
has_repo3=$(grep -c "org/repo3" "$test_dir/output4.csv" || true)
has_repo4=$(grep -c "org/repo4" "$test_dir/output4.csv" || true)

if [ "$line_count" -eq 5 ] && [ "$has_repo1_old_uri" -eq 1 ] && [ "$has_repo2_new_uri" -eq 1 ] && [ "$has_repo3" -eq 1 ] && [ "$has_repo4" -eq 1 ]; then
    echo "✅ Test 4 PASSED: Mixed scenario handled correctly"
    echo "  - repo1: preserved old publishUri (new was empty)"
    echo "  - repo2: updated publishUri (new was non-empty)"
    echo "  - repo3: added with empty fields"
    echo "  - repo4: added as new entry"
else
    echo "❌ Test 4 FAILED: Mixed scenario not handled correctly"
fi

echo ""
echo "All tests completed!"