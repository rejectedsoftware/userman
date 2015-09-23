import vibe.http.fileserver;
import vibe.http.router;
import vibe.http.server;

import userman.api;
import userman.db.controller;
import userman.web;

shared static this()
{
	auto usettings = new UserManSettings;
	usettings.requireAccountValidation = false;
	usettings.databaseURL = "file://./testdb/";

	auto uctrl = createUserManController(usettings);
	auto api = createLocalUserManAPI(uctrl);
	//auto api = createUserManRestAPI(URL("http://127.0.0.1:2113"))

	auto router = new URLRouter;
	router.get("/", staticTemplate!"home.dt");
	router.registerUserManWebInterface(uctrl);
	router.get("*", serveStaticFiles("public/"));
	
	auto settings = new HTTPServerSettings;
	settings.sessionStore = new MemorySessionStore;
	settings.port = 8080;
	listenHTTP(settings, router);
}
