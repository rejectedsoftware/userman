import vibe.d;

import userman.db;
import userman.controller;

static this()
{
	auto db = connectMongoDB("127.0.0.1");
	auto udb = new UserDB(db, "userdb");
	auto uctrl = new UserDBController(udb);

	auto router = new UrlRouter;
	uctrl.register(router, "/");
	router.get("/", staticTemplate!"home.dt");
	
	auto settings = new HttpServerSettings;
	settings.sessionStore = new MemorySessionStore;
	settings.port = 8080;
	
	listenHttp(settings, router);
}
