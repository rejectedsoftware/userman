/**
	Web interface implementation

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.web;

public import userman.controller;

import vibe.core.log;
import vibe.crypto.passwordhash;
import vibe.http.router;
import vibe.textfilter.urlencode;
import vibe.utils.validation;

import std.exception;


class UserManWebInterface {
	private {
		UserManController m_controller;
		string m_prefix;
	}
	
	this(UserManController ctrl, string prefix = "/")
	{
		m_controller = ctrl;
		m_prefix = prefix;
	}
	
	void register(UrlRouter router)
	{
		router.get(m_prefix~"login", &showLogin);
		router.post(m_prefix~"login", &login);
		router.get(m_prefix~"logout", &logout);
		router.get(m_prefix~"register", &showRegister);
		router.post(m_prefix~"register", &register);
		router.get(m_prefix~"resend_activation", &showResendActivation);
		router.post(m_prefix~"resend_activation", &resendActivation);
		router.get(m_prefix~"activate", &activate);
		router.get(m_prefix~"profile", auth(&showProfile));
		router.post(m_prefix~"profile", auth(&changeProfile));
	}
	
	HttpServerRequestDelegate auth(void delegate(HttpServerRequest, HttpServerResponse, User) callback)
	{
		void requestHandler(HttpServerRequest req, HttpServerResponse res)
		{
			if( !req.session ){
				res.redirect(m_prefix~"login?redirect="~urlEncode(req.path));
			} else {
				auto usr = m_controller.getUserByName(req.session["userName"]);
				callback(req, res, usr);
			}
		}
		
		return &requestHandler;
	}
	HttpServerRequestDelegate auth(HttpServerRequestDelegate callback)
	{
		return auth((req, res, user){ callback(req, res); });
	}
	
	HttpServerRequestDelegate ifAuth(void delegate(HttpServerRequest, HttpServerResponse, User) callback)
	{
		void requestHandler(HttpServerRequest req, HttpServerResponse res)
		{
			if( !req.session ) return;
			auto usr = m_controller.getUserByName(req.session["userName"]);
			callback(req, res, usr);
		}
		
		return &requestHandler;
	}

	void updateProfile(User user, HttpServerRequest req)
	{
		if( m_controller.settings.useUserNames ){
			if( auto pv = "name" in req.form ) user.fullName = *pv;
			if( auto pv = "email" in req.form ) user.email = *pv;
		} else {
			if( auto pv = "email" in req.form ) user.email = user.name = *pv;
		}
		if( auto pv = "full_name" in req.form ) user.fullName = *pv;

		if( auto pv = "password" in req.form ){
			enforce(user.auth.method == "password", "User account has no password authentication.");
			auto pconf = "password_confirmation" in req.form;
			enforce(pconf !is null, "Missing password confirmation.");
			validatePassword(*pv, *pconf);
			user.auth.passwordHash = generateSimplePasswordHash(*pv);
		}

		m_controller.updateUser(user);

		req.session["userFullName"] = user.fullName;
		req.session["userEmail"] = user.email;
	}
	
	protected void showLogin(HttpServerRequest req, HttpServerResponse res)
	{
		string error;
		auto prdct = "redirect" in req.query;
		string redirect = prdct ? *prdct : "";
		res.renderCompat!("userman.login.dt",
			HttpServerRequest, "req",
			string, "error",
			string, "redirect",
			UserManSettings, "settings")(req, error, redirect, m_controller.settings);
	}
	
	protected void login(HttpServerRequest req, HttpServerResponse res)
	{
		auto username = req.form["name"];
		auto password = req.form["password"];
		auto prdct = "redirect" in req.form;

		User user;
		try {
			user = m_controller.getUserByName(username);
			enforce(user.active, "The account is not yet activated.");
			enforce(testSimplePasswordHash(user.auth.passwordHash, password),
				"The password you entered is not correct.");
			
			auto session = res.startSession();
			session["userEmail"] = user.email;
			session["userName"] = username;
			session["userFullName"] = user.fullName;
			res.redirect(prdct ? *prdct : m_prefix);
		} catch( Exception e ){
			string error = e.msg;
			string redirect = prdct ? *prdct : "";
			res.renderCompat!("userman.login.dt",
				HttpServerRequest, "req",
				string, "error",
				string, "redirect",
				UserManSettings, "settings")(req, error, redirect, m_controller.settings);
		}
	}
	
	protected void logout(HttpServerRequest req, HttpServerResponse res)
	{
		if( req.session ){
			res.terminateSession();
			req.session = null;
		}
		res.headers["Refresh"] = "3; url="~m_controller.settings.serviceUrl;
		res.renderCompat!("userman.logout.dt",
			HttpServerRequest, "req")(Variant(req));
	}

	protected void showRegister(HttpServerRequest req, HttpServerResponse res)
	{
		string error;
		res.renderCompat!("userman.register.dt",
			HttpServerRequest, "req",
			string, "error",
			UserManSettings, "settings")(req, error, m_controller.settings);
	}
	
	protected void register(HttpServerRequest req, HttpServerResponse res)
	{
		string error;
		try {
			auto email = validateEmail(req.form["email"]);
			if( !m_controller.settings.useUserNames ) req.form["name"] = email;
			auto name = validateUserName(req.form["name"]);
			auto fullname = req.form["fullName"];
			auto password = validatePassword(req.form["password"], req.form["passwordConfirmation"]);
			m_controller.registerUser(email, name, fullname, password);

			if( m_controller.settings.requireAccountValidation ){
				res.renderCompat!("userman.register_activate.dt",
					HttpServerRequest, "req",
					string, "error")(Variant(req), Variant(error));
			} else {
				login(req, res);
			}
		} catch( Exception e ){
			error = e.msg;
			res.renderCompat!("userman.register.dt",
				HttpServerRequest, "req",
				string, "error",
				UserManSettings, "settings")(req, error, m_controller.settings);
		}
	}
	
	protected void showResendActivation(HttpServerRequest req, HttpServerResponse res)
	{
		string error;
		res.renderCompat!("userman.resend_activation.dt",
			HttpServerRequest, "req",
			string, "error")(Variant(req), Variant(error));
	}

	protected void resendActivation(HttpServerRequest req, HttpServerResponse res)
	{
		try {
			m_controller.resendActivation(req.form["email"]);
			res.renderCompat!("userman.resend_activation_done.dt",
				HttpServerRequest, "req")(Variant(req));
		} catch( Exception e ){
			string error = "Failed to send activation mail. Please try again later.";
			error ~= e.toString();
			res.renderCompat!("userman.resend_activation.dt",
				HttpServerRequest, "req",
				string, "error")(Variant(req), Variant(error));
		}
	}
	
	protected void activate(HttpServerRequest req, HttpServerResponse res)
	{
		auto email = req.query["email"];
		auto code = req.query["code"];
		m_controller.activateUser(email, code);
		auto user = m_controller.getUserByEmail(email);
		auto session = res.startSession();
		res.renderCompat!("userman.activate.dt",
			HttpServerRequest, "req")(Variant(req));
	}
	
	protected void showProfile(HttpServerRequest req, HttpServerResponse res, User user)
	{
		string error = req.params.get("error", null);
		res.renderCompat!("userman.profile.dt",
			HttpServerRequest, "req",
			User, "user",
			string, "error")(Variant(req), Variant(user), Variant(error));
	}
	
	protected void changeProfile(HttpServerRequest req, HttpServerResponse res, User user)
	{
		try {
			updateProfile(user, req);
		} catch( Exception e ){
			req.params["error"] = e.msg;
			showProfile(req, res, user);
		}
	}
}
