"""Identical FastAPI app for both saltare and uvicorn benchmarks."""

from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def root():
    return {"hello": "world"}
