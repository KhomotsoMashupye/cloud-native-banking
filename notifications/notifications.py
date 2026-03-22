from fastapi import FastAPI

app = FastAPI(title="Notification Service")

@app.post("/notify")
def notify(message: str):
    return {"status": "notification queued"}