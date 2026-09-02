.PHONY: backend-test backend-run update-cookies

backend-test:
	cd backend && .venv/bin/pytest -q

backend-run:
	cd backend && .venv/bin/uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

update-cookies:
	@test -n "$(FILE)" || (echo "Usage: make update-cookies FILE=/path/to/cookies.txt" >&2; exit 2)
	./scripts/update-youtube-cookies.sh "$(FILE)"
