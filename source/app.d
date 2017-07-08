/**
	Application entry point for a UserMan REST server and web admin frontend.

	Use a local "settings.json" file to configure the server.

	Copyright: © 2012-2015 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module app;

import vibe.core.args;
import vibe.core.core;
import vibe.core.log;
import vibe.http.fileserver;
import vibe.http.router;
import vibe.http.server;

import userman.api;
import userman.db.controller;
import userman.webadmin;

shared static this()
{
	ushort restport = 0;
	string restintf = "127.0.0.1";
	ushort webport = 0;
	string webintf = "127.0.0.1";
	readOption("admin-port", &webport, "TCP port to listen use for a web admin interface.");
	readOption("admin-intf", &webintf, "Network interface address to use for the web admin interface (127.0.0.1 by default)");
	readOption("rest-port", &restport, "TCP port to listen for REST API requests.");
	readOption("rest-intf", &restintf, "Network interface address to use for the REST API server (127.0.0.1 by default)");

	// TODO: read settings.json

	if (!restport && !webport) {
		logInfo("Neither -rest-port, nor -web-port specified. Exiting.");
		logInfo("Run with --help to get a list of possible command line options.");
		runTask({ exitEventLoop(); });
		return;
	}

	auto usettings = new UserManSettings;
	usettings.requireActivation = false;
	usettings.databaseURL = "file://./testdb/";

	auto uctrl = createUserManController(usettings);
	auto api = createLocalUserManAPI(uctrl);


	if (webport) {
		auto router = new URLRouter;
		router.registerUserManWebAdmin(api);
		//router.registerUserManRestInterface(uctrl);
		router.get("*", serveStaticFiles("public/"));

		auto settings = new HTTPServerSettings;
		settings.bindAddresses = [webintf];
		settings.sessionStore = new MemorySessionStore;
		settings.port = webport;
		listenHTTP(settings, router);
	}

	if (restport) {
		auto router = new URLRouter;
		router.registerUserManRestInterface(uctrl);

		auto settings = new HTTPServerSettings;
		settings.bindAddresses = [restintf];
		settings.port = restport;
		listenHTTP(settings, router);
	}
}
