.PHONY: test lint

test:
	@fail=0; for t in tests/*.sh; do [ -e "$$t" ] || continue; echo "== $$t"; bash "$$t" || fail=1; done; exit $$fail

lint:
	shellcheck bin/* extras/bin-wrapper tests/*.sh
	@# Claude Code replaces $$0, $$1, ... in a command or skill file with the invocation's arguments
	@if grep -nE '\$$[0-9]' commands/*.md skills/*/SKILL.md; then echo 'lint: a positional $$N in a command or skill file is replaced with an argument at load time; write it another way'; exit 1; fi
