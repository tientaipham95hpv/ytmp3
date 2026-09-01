.PHONY: backend-test backend-run

backend-test:
	cd backend && .venv/bin/pytest -q

backend-run:
	cd backend && .venv/bin/uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
