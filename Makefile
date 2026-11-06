.PHONY: test lint

test:
	@fail=0; for t in tests/*.sh; do [ -e "$$t" ] || continue; echo "== $$t"; bash "$$t" || fail=1; done; exit $$fail

lint:
	shellcheck bin/* extras/bin-wrapper tests/*.sh
