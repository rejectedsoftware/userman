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
	
	void register(URLRouter router)
	{
		router.get(m_prefix~"login", &showLogin);
		router.post(m_prefix~"login", &login);
		router.get(m_prefix~"logout", &logout);
		router.get(m_prefix~"register", &showRegister);
		router.post(m_prefix~"register", &register);
		router.get(m_prefix~"resend_activation", &showResendActivation);
		router.post(m_prefix~"resend_activation", &resendActivation);
		router.get(m_prefix~"activate", &activate);
		router.get(m_prefix~"forgot_login", &showForgotPassword);
		router.post(m_prefix~"forgot_login", &sendPasswordReset);
		router.get(m_prefix~"reset_password", &showResetPassword);
		router.post(m_prefix~"reset_password", &resetPassword);
		router.get(m_prefix~"profile", auth(&showProfile));
		router.post(m_prefix~"profile", auth(&changeProfile));
	}
	
	HTTPServerRequestDelegate auth(void delegate(HTTPServerRequest, HTTPServerResponse, User) callback)
	{
		void requestHandler(HTTPServerRequest req, HTTPServerResponse res)
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
	HTTPServerRequestDelegate auth(HTTPServerRequestDelegate callback)
	{
		return auth((req, res, user){ callback(req, res); });
	}
	
	HTTPServerRequestDelegate ifAuth(void delegate(HTTPServerRequest, HTTPServerResponse, User) callback)
	{
		void requestHandler(HTTPServerRequest req, HTTPServerResponse res)
		{
			if( !req.session ) return;
			auto usr = m_controller.getUserByName(req.session["userName"]);
			callback(req, res, usr);
		}
		
		return &requestHandler;
	}

	void updateProfile(User user, HTTPServerRequest req)
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
	
	protected void showLogin(HTTPServerRequest req, HTTPServerResponse res)
	{
		string error;
		auto prdct = "redirect" in req.query;
		string redirect = prdct ? *prdct : "";
		res.renderCompat!("userman.login.dt",
			HTTPServerRequest, "req",
			string, "error",
			string, "redirect",
			UserManSettings, "settings")(req, error, redirect, m_controller.settings);
	}
	
	protected void login(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto username = req.form["name"];
		auto password = req.form["password"];
		auto prdct = "redirect" in req.form;

		User user;
		try {
			user = m_controller.getUserByEmailOrName(username);
			enforce(user.active, "The account is not yet activated.");
			enforce(testSimplePasswordHash(user.auth.passwordHash, password),
				"The password you entered is not correct.");
			
			auto session = req.session;
			if (!session) session = res.startSession();
			session["userEmail"] = user.email;
			session["userName"] = user.name;
			session["userFullName"] = user.fullName;
			session["userID"] = user._id.toString();
			res.redirect(prdct ? *prdct : m_prefix);
		} catch( Exception e ){
			logDebug("Error logging in: %s", e.toString());
			string error = e.msg;
			string redirect = prdct ? *prdct : "";
			res.renderCompat!("userman.login.dt",
				HTTPServerRequest, "req",
				string, "error",
				string, "redirect",
				UserManSettings, "settings")(req, error, redirect, m_controller.settings);
		}
	}
	
	protected void logout(HTTPServerRequest req, HTTPServerResponse res)
	{
		if( req.session ){
			res.terminateSession();
			req.session = Session.init;
		}
		res.headers["Refresh"] = "3; url="~m_controller.settings.serviceUrl.toString();
		res.renderCompat!("userman.logout.dt",
			HTTPServerRequest, "req")(req);
	}

	protected void showRegister(HTTPServerRequest req, HTTPServerResponse res)
	{
		string error;
		res.renderCompat!("userman.register.dt",
			HTTPServerRequest, "req",
			string, "error",
			UserManSettings, "settings")(req, error, m_controller.settings);
	}
	
	protected void register(HTTPServerRequest req, HTTPServerResponse res)
	{
		string error;
		try {
			auto email = validateEmail(req.form["email"]);
			if (!m_controller.settings.useUserNames) req.form["name"] = email;
			else validateUserName(req.form["name"]);
			auto name = req.form["name"];
			auto fullname = req.form["fullName"];
			auto password = validatePassword(req.form["password"], req.form["passwordConfirmation"]);
			m_controller.registerUser(email, name, fullname, password);

			if( m_controller.settings.requireAccountValidation ){
				res.renderCompat!("userman.register_activate.dt",
					HTTPServerRequest, "req",
					string, "error")(req, error);
			} else {
				login(req, res);
			}
		} catch( Exception e ){
			error = e.msg;
			res.renderCompat!("userman.register.dt",
				HTTPServerRequest, "req",
				string, "error",
				UserManSettings, "settings")(req, error, m_controller.settings);
		}
	}
	
	protected void showResendActivation(HTTPServerRequest req, HTTPServerResponse res)
	{
		string error = req.params.get("error", null);
		res.renderCompat!("userman.resend_activation.dt",
			HTTPServerRequest, "req",
			string, "error")(req, error);
	}

	protected void resendActivation(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {
			m_controller.resendActivation(req.form["email"]);
			res.renderCompat!("userman.resend_activation_done.dt",
				HTTPServerRequest, "req")(req);
		} catch( Exception e ){
			string error = "Failed to send activation mail. Please try again later.";
			error ~= e.toString();
			res.renderCompat!("userman.resend_activation.dt",
				HTTPServerRequest, "req",
				string, "error")(req, error);
		}
	}

	protected void activate(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto email = req.query["email"];
		auto code = req.query["code"];
		m_controller.activateUser(email, code);
		auto user = m_controller.getUserByEmail(email);
		auto session = req.session;
		if (!session) session = res.startSession();
		session["userEmail"] = user.email;
		session["userName"] = user.name;
		session["userFullName"] = user.fullName;
		res.renderCompat!("userman.activate.dt",
			HTTPServerRequest, "req")(req);
	}
	
	protected void showForgotPassword(HTTPServerRequest req, HTTPServerResponse res)
	{
		string error = req.params.get("error", null);
		res.renderCompat!("userman.forgot_login.dt",
			HTTPServerRequest, "req",
			string, "error")(req, error);
	}

	protected void sendPasswordReset(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {
			m_controller.requestPasswordReset(req.form["email"]);
		} catch(Exception e){
			req.params["error"] = e.msg;
			showForgotPassword(req, res);
			return;
		}

		res.renderCompat!("userman.forgot_login_sent.dt",
			HTTPServerRequest, "req")(req);
	}

	protected void showResetPassword(HTTPServerRequest req, HTTPServerResponse res)
	{
		string error = req.params.get("error", null);
		res.renderCompat!("userman.reset_password.dt",
			HTTPServerRequest, "req",
			string, "error")(req, error);
	}

	protected void resetPassword(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {
			auto password = req.form["password"];
			auto password_conf = req.form["password_confirmation"];
			validatePassword(password, password_conf);
			m_controller.resetPassword(req.form["email"], req.form["code"], password);
		} catch(Exception e){
			req.params["error"] = e.msg;
			showResetPassword(req, res);
			return;
		}

		res.headers["Refresh"] = "3; url=" ~ m_controller.settings.serviceUrl.toString();
		res.renderCompat!("userman.reset_password_done.dt",
			HTTPServerRequest, "req")(req);
	}

	protected void showProfile(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		string error = req.params.get("error", null);
		req.form["full_name"] = user.fullName;
		req.form["email"] = user.email;
		res.renderCompat!("userman.profile.dt",
			HTTPServerRequest, "req",
			User, "user",
			string, "error")(req, user, error);
	}
	
	protected void changeProfile(HTTPServerRequest req, HTTPServerResponse res, User user)
	{
		try {
			updateProfile(user, req);
			res.redirect(m_prefix);
		} catch( Exception e ){
			req.params["error"] = e.msg;
			showProfile(req, res, user);
		}
	}
}
