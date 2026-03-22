from fastapi import FastAPI
from pydantic import BaseModel
import uuid

app = FastAPI(title="Accounts Service")

accounts = {}

class AccountCreate(BaseModel):
    customer_id: str
    initial_balance: float

@app.post("/accounts")
def create_account(data: AccountCreate):
    account_id = str(uuid.uuid4())
    accounts[account_id] = {
        "customer_id": data.customer_id,
        "balance": data.initial_balance
    }
    return {"account_id": account_id}

@app.get("/accounts/{account_id}")
def get_account(account_id: str):
    return accounts.get(account_id, {"error": "Account not found"})