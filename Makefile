SHELL := /bin/bash

.PHONY: test lint check check-researcher-runtime

test:
	python3 -m unittest discover -s tests -p 'test_*.py' -v

lint:
	./Meta/scripts/ci-check.sh --lint-only

check:
	./Meta/scripts/ci-check.sh

check-researcher-runtime:
	./Meta/scripts/check-researcher-runtime.sh
