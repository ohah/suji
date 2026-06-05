import suji
import json


def ping(request_json):
    return json.dumps({"msg": "pong"})


def greet(request_json):
    return json.dumps({"greeting": "Hello from Python!"})


suji.handle("ping", ping)
suji.handle("greet", greet)
