# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Fail unless this tox environment runs the Python in EXPECT_PYTHON."""

import os
import sys

want = os.environ.get("EXPECT_PYTHON", "")
got = "{}.{}".format(*sys.version_info[:2])
print(f"tox environment Python: {sys.version}")
if got != want:
    sys.exit(f"expected Python {want or '(unset)'}, got {got}")
