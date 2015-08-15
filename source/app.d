/**
	Application entry point for a UserMan REST server and web admin frontend.

	Use a local "settings.json" file to configure the server.

	Copyright: © 2012-2015 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
import vibe.d;

import userman.api;
import userman.db.controller;
import userman.webadmin;

shared static this()
{
	// TODO: read settings.json

	auto usettings = new UserManSettings;
	usettings.requireAccountValidation = false;
	usettings.databaseURL = "file://./testdb/";

	auto uctrl = createUserManController(usettings);
	auto api = createLocalUserManAPI(uctrl);

	auto router = new URLRouter;
	router.registerUserManWebAdmin(api);
	//router.registerUserManRestInterface(uctrl);
	router.get("*", serveStaticFiles("public/"));
	
	auto settings = new HTTPServerSettings;
	settings.sessionStore = new MemorySessionStore;
	settings.port = 8080;
	listenHTTP(settings, router);
}
