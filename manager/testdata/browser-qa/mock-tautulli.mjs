import http from "node:http";

const listenAddress = "127.0.0.1";
const listenPort = 18181;
const apiKey = "fictional-browser-qa-api-key";

const users = Array.from({ length: 78 }, (_, index) => ({
  user_id: String(index + 1),
  friendly_name: index === 0 ? "Fictional Admin" : `Fictional Viewer ${String(index + 1).padStart(2, "0")}`,
  email: index === 0
    ? "viewer@example.com"
    : index === 1
      ? "unmatched-legacy@example.org"
      : index === 2
        ? ""
        : `viewer${index + 1}@example.org`,
  is_active: 1,
  do_notify: 1,
  is_admin: index === 0 ? 1 : 0,
}));

const server = http.createServer((request, response) => {
  const target = new URL(request.url || "/", `http://${listenAddress}:${listenPort}`);
  if (target.pathname !== "/api/v2" || target.searchParams.get("apikey") !== apiKey) {
    response.writeHead(401, { "content-type": "text/plain; charset=utf-8" });
    response.end("unauthorized");
    return;
  }

  let data;
  switch (target.searchParams.get("cmd")) {
    case "get_libraries":
      data = [
        { section_id: "1", section_name: "Fictional Movies", section_type: "movie", is_active: 1, count: 40 },
        { section_id: "2", section_name: "Fictional Shows", section_type: "show", is_active: 1, count: 20 },
        { section_id: "3", section_name: "Fictional Family", section_type: "movie", is_active: 1, count: 18 },
      ];
      break;
    case "get_user_names":
      data = users.map(({ user_id, friendly_name }) => ({ user_id, friendly_name }));
      break;
    case "get_users":
      data = users.map((user, index) => {
        if (index > 1) return user;
        const { email: _email, ...withoutEmail } = user;
        return withoutEmail;
      });
      break;
    case "get_users_table":
      if (target.searchParams.get("start") !== "0" || target.searchParams.get("length") !== "2000") {
        response.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
        response.end("invalid fixture table window");
        return;
      }
      data = { data: users };
      break;
    default:
      response.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
      response.end("unsupported fixture command");
      return;
  }

  response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify({ response: { result: "success", data } }));
});

server.listen(listenPort, listenAddress);

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
