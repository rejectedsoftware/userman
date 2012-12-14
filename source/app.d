/**
	Application entry point for a small test application.

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
import vibe.d;

import userman.web;

static this()
{
	auto usettings = new UserManSettings;
	auto uctrl = new UserManController(usettings);
	auto uweb = new UserManWebInterface(uctrl);

	auto router = new UrlRouter;
	uweb.register(router);
	router.get("/", staticTemplate!"home.dt");
	
	auto settings = new HttpServerSettings;
	settings.sessionStore = new MemorySessionStore;
	settings.port = 8080;
	
	listenHttp(settings, router);
}
