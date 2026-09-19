from flask import Flask
app = Flask(__name__)

@app.get("/health")
def health():
    return {"status": "ok"}

# from flask library we're importing Flask class
# seting an instance of that class called "app"
# (__name__) is a Python variable holding the current module's name
# which Flask uses to locate files relative to your app
# @app line is a decorator, recieving the health function
# plain english, when someone makes a GET request on /health endpoint, run the function below