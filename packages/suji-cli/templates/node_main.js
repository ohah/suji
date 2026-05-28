const { handle } = require("@suji/node");

handle("ping", () => ({ msg: "pong" }));

handle("greet", (data = {}) => ({
  msg: data.name || "world",
  greeting: "Hello from Node.js!",
}));
