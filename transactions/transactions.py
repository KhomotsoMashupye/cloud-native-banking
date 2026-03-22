from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="Transactions Service")

class Transaction(BaseModel):
    from_account: str
    to_account: str
    amount: float

@app.post("/transactions")
def create_transaction(tx: Transaction):
    return {
        "status": "accepted",
        "from": tx.from_account,
        "to": tx.to_account,
        "amount": tx.amount
    }