/**
	Application entry point for a small test application.

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
import vibe.d;

import userman.web;
import userman.mongocontroller;

shared static this()
{
	auto usettings = new UserManSettings;
	auto uctrl = new MongoUserManController(usettings);
	auto uweb = new UserManWebInterface(uctrl);

	auto router = new URLRouter;
	router.registerUserManWebInterface(uctrl);
	router.get("/", staticTemplate!"home.dt");
	
	auto settings = new HTTPServerSettings;
	settings.sessionStore = new MemorySessionStore;
	settings.port = 8080;
	
	listenHTTP(settings, router);
}
