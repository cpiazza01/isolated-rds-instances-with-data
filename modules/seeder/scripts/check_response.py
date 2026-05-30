#!/usr/bin/env python3
"""
Validates an aws lambda invoke response file, failing with a non-zero exit
code if the Lambda reported a function error.

Usage: python check_response.py <response_file>

aws lambda invoke exits 0 even when the Lambda itself throws an exception —
the error is recorded in the JSON as a FunctionError field, not the process
exit code. This script surfaces those failures so terraform local-exec
provisioners fail the apply rather than silently succeeding.
"""
import json
import sys


def main() -> None:
    path = sys.argv[1]
    try:
        with open(path) as f:
            response = json.load(f)
    except FileNotFoundError:
        print(f"ERROR: Response file not found: {path}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"ERROR: Could not parse Lambda response JSON from {path}: {e}", file=sys.stderr)
        sys.exit(1)

    if response.get("FunctionError"):
        print(
            f"ERROR: Seeder Lambda execution failed.\n"
            f"FunctionError: {response['FunctionError']}\n"
            f"Full response: {json.dumps(response, indent=2)}",
            file=sys.stderr,
        )
        sys.exit(1)

    body = response.get("body", "(no body)")
    print(f"Seeder completed successfully — {body}")


if __name__ == "__main__":
    main()
