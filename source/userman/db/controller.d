/**
	Database abstraction layer

	Copyright: © 2012-2015 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.db.controller;

public import userman.userman;
import userman.id;

import vibe.data.serialization;
import vibe.db.mongo.mongo;
import vibe.http.router;
import vibe.mail.smtp;
import vibe.stream.memory;
import vibe.utils.validation;
import diet.html;

import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
import std.random;
import std.string;
import std.typecons : Nullable;


UserManController createUserManController(UserManSettings settings)
{
	import userman.db.file;
	import userman.db.mongo;
	import userman.db.redis;

	auto url = settings.databaseURL;
	if (url.startsWith("redis://")) return new RedisUserManController(settings);
	else if (url.startsWith("mongodb://")) return new MongoUserManController(settings);
	else if (url.startsWith("file://")) return new FileUserManController(settings);
	else throw new Exception("Unknown URL schema: "~url);
}

class UserManController {
@safe:
	protected {
		UserManSettings m_settings;
	}

	this(UserManSettings settings)
	{
		m_settings = settings;
	}

	@property UserManSettings settings() { return m_settings; }

	abstract bool isEmailRegistered(string email);

	void validateUser(const ref User usr)
	{
		enforce(usr.name.length >= 3, "User names must be at least 3 characters long.");
		validateEmail(usr.email);
	}

	abstract User.ID addUser(ref User usr);

	User.ID registerUser(string email, string name, string full_name, string password)
	{
		email = email.toLower();
		name = name.toLower();

		validateEmail(email);
		validatePassword(password, password);

		auto need_activation = m_settings.requireActivation;
		User user;
		user.active = !need_activation;
		user.name = name;
		user.fullName = full_name;
		user.auth.method = "password";
		user.auth.passwordHash = generatePasswordHash(password);
		assert(validatePasswordHash(user.auth.passwordHash, password));
		user.email = email;
		if( need_activation )
			user.activationCode = generateActivationCode();

		addUser(user);

		if( need_activation )
			resendActivation(email);

		return user.id;
	}

	User.ID inviteUser(string email, string full_name, string message, bool send_mail = true)
	{
		email = email.toLower();

		validateEmail(email);

		try {
			return getUserByEmail(email).id;
		}
		catch (Exception e) {
			User user;
			user.email = email;
			user.name = email;
			user.fullName = full_name;
			addUser(user);

			if( m_settings.mailSettings ){
				auto msg = appender!string;
				auto serviceName = m_settings.serviceName;
				auto serviceURL = m_settings.serviceURL;
				msg.compileHTMLDietFile!("userman.mail.invitation.dt", user, serviceName, serviceURL);

				auto mail = new Mail;
				mail.headers["From"] = m_settings.serviceName ~ " <" ~ m_settings.serviceEmail ~ ">";
				mail.headers["To"] = email;
				mail.headers["Subject"] = "Invitation";
				mail.headers["Content-Type"] = "text/html; charset=UTF-8";
				mail.bodyText = cast(string)msg.data();

				sendMail(m_settings.mailSettings, mail);
			}

			return user.id;
		}
	}

	Nullable!(User.ID) testLogin(string name, string password)
	{
		string password_ = password;
		auto user = getUserByEmailOrName(name);
		assert(password == password_); // this used to be false to to a Nullable related codegen issue
		Nullable!(User.ID) ret;
		if (validatePasswordHash(user.auth.passwordHash, password_))
			ret = user.id;
		return ret;
	}

	void activateUser(string email, string activation_code)
	{
		email = email.toLower();

		auto user = getUserByEmail(email);
		enforce(!user.active, "This user account is already activated.");
		enforce(user.activationCode == activation_code, "The activation code provided is not valid.");
		user.active = true;
		user.activationCode = "";
		updateUser(user);
	}

	void resendActivation(string email)
	{
		email = email.toLower();

		auto user = getUserByEmail(email);
		enforce(!user.active, "The user account is already active.");

		auto msg = appender!string();
		auto serviceName = m_settings.serviceName;
		auto serviceURL = m_settings.serviceURL;
		msg.compileHTMLDietFile!("userman.mail.activation.dt", user, serviceName, serviceURL);

		auto mail = new Mail;
		mail.headers["From"] = m_settings.serviceName ~ " <" ~ m_settings.serviceEmail ~ ">";
		mail.headers["To"] = email;
		mail.headers["Subject"] = "Account activation";
		mail.headers["Content-Type"] = "text/html; charset=UTF-8";
		mail.bodyText = cast(string)msg.data();

		sendMail(m_settings.mailSettings, mail);
	}

	void requestPasswordReset(string email)
	{
		auto usr = getUserByEmail(email);

		string reset_code = generateActivationCode();
		SysTime expire_time = Clock.currTime() + dur!"hours"(24);
		usr.resetCode = reset_code;
		usr.resetCodeExpireTime = expire_time;
		updateUser(usr);

		if( m_settings.mailSettings ){
			auto msg = appender!string();
			scope user = () @trusted { return &usr; } ();
			auto settings = m_settings;
			msg.compileHTMLDietFile!("userman.mail.reset_password.dt", user, reset_code, settings);

			auto mail = new Mail;
			mail.headers["From"] = m_settings.serviceName ~ " <" ~ m_settings.serviceEmail ~ ">";
			mail.headers["To"] = email;
			mail.headers["Subject"] = "Account recovery";
			mail.headers["Content-Type"] = "text/html; charset=UTF-8";
			mail.bodyText = cast(string)msg.data();
			sendMail(m_settings.mailSettings, mail);
		}
	}

	void resetPassword(string email, string reset_code, string new_password)
	{
		validatePassword(new_password, new_password);
		auto usr = getUserByEmail(email);
		enforce(usr.resetCode.length > 0, "No password reset request was made.");
		enforce(Clock.currTime() < usr.resetCodeExpireTime, "Reset code is expired, please request a new one.");
		auto code = usr.resetCode;
		usr.resetCode = "";
		updateUser(usr);
		enforce(reset_code == code, "Invalid request code, please request a new one.");
		usr.auth.passwordHash = generatePasswordHash(new_password);
		updateUser(usr);
	}

	abstract User getUser(User.ID id);

	abstract User getUserByName(string name);

	abstract User getUserByEmail(string email);

	abstract User getUserByEmailOrName(string email_or_name);

	abstract void enumerateUsers(long first_user, long max_count, scope void delegate(ref User usr) @safe del);
	final void enumerateUsers(long first_user, long max_count, scope void delegate(ref User usr) del) {
		enumerateUsers(first_user, max_count, (ref usr) @trusted { del(usr); });
	}

	abstract long getUserCount();

	abstract void deleteUser(User.ID user_id);

	abstract void updateUser(const ref User user);
	abstract void setEmail(User.ID user, string email);
	abstract void setFullName(User.ID user, string full_name);
	abstract void setPassword(User.ID user, string password);
	abstract void setProperty(User.ID user, string name, Json value);
	abstract void removeProperty(User.ID user, string name);

	abstract void addGroup(string id, string description);
	abstract void removeGroup(string name);
	abstract void setGroupDescription(string name, string description);
	abstract long getGroupCount();
	abstract Group getGroup(string id);
	abstract void enumerateGroups(long first_group, long max_count, scope void delegate(ref Group grp) @safe del);
	final void enumerateGroups(long first_group, long max_count, scope void delegate(ref Group grp) del) {
		enumerateGroups(first_group, max_count, (ref grp) @trusted { del(grp); });
	}
	abstract void addGroupMember(string group, User.ID user);
	abstract void removeGroupMember(string group, User.ID user);
	abstract long getGroupMemberCount(string group);
	abstract void enumerateGroupMembers(string group, long first_member, long max_count, scope void delegate(User.ID usr) @safe del);
	final void enumerateGroupMembers(string group, long first_member, long max_count, scope void delegate(User.ID usr) del) {
		enumerateGroupMembers(group, first_member, max_count, (usr) @trusted { del(usr); });
	}
	deprecated Group getGroupByName(string id) { return getGroup(id); }

	/** Test a group ID for validity.

		Valid group IDs consist of one or more dot separated identifiers, where
		each idenfifiers must contain only ASCII alphanumeric characters or
		underscores. Each identifier must begin with an alphabetic or underscore
		character.
	*/
	static bool isValidGroupID(string name)
	{
		import std.ascii : isAlpha, isDigit;
		import std.algorithm : splitter;

		if (name.length < 1) return false;
		foreach (p; name.splitter('.')) {
			if (p.length < 0) return false;
			if (!p[0].isAlpha && p[0] != '_') return false;
			if (p.canFind!(ch => !ch.isAlpha && !ch.isDigit && ch != '_'))
				return false;
		}
		return true;
	}
}

struct User {
	alias .ID!User ID;
	@(.name("_id")) ID id;
	bool active;
	bool banned;
	string name;
	string fullName;
	string email;
	string[] groups;
	string activationCode;
	string resetCode;
	SysTime resetCodeExpireTime;
	AuthInfo auth;
	Json[string] properties;

	bool isInGroup(string group) const { return groups.countUntil(group) >= 0; }
}

struct AuthInfo {
	string method = "password";
	string passwordHash;
	string token;
	string secret;
	string info;
}

struct Group {
	string id;
	string description;
	@optional Json[string] properties;
}


string generateActivationCode()
@safe {
	auto ret = appender!string();
	foreach( i; 0 .. 10 ){
		auto n = cast(char)uniform(0, 62);
		if( n < 26 ) ret.put(cast(char)('a'+n));
		else if( n < 52 ) ret.put(cast(char)('A'+n-26));
		else ret.put(cast(char)('0'+n-52));
	}
	return ret.data();
}

string generatePasswordHash(string password)
@safe {
	import std.base64 : Base64;

	// FIXME: use a more secure hash method
	ubyte[4] salt;
	foreach( i; 0 .. 4 ) salt[i] = cast(ubyte)uniform(0, 256);
	ubyte[16] hash = md5hash(salt, password);
	return Base64.encode(salt ~ hash).idup;
}

bool validatePasswordHash(string password_hash, string password)
@safe {
	import std.base64 : Base64;

	// FIXME: use a more secure hash method
	import std.string : format;
	ubyte[] upass = Base64.decode(password_hash);
	enforce(upass.length == 20, format("Invalid binary password hash length: %s", upass.length));
	auto salt = upass[0 .. 4];
	auto hashcmp = upass[4 .. 20];
	ubyte[16] hash = md5hash(salt, password);
	return hash == hashcmp;
}

unittest {
	auto h = generatePasswordHash("foobar");
	assert(!validatePasswordHash(h, "foo"));
	assert(validatePasswordHash(h, "foobar"));
}

private ubyte[16] md5hash(ubyte[] salt, string[] strs...)
@safe {
	static if( __traits(compiles, {import std.digest.md;}) ){
		import std.digest.md;
		MD5 ctx;
		ctx.start();
		ctx.put(salt);
		foreach( s; strs ) ctx.put(cast(const(ubyte)[])s);
		return ctx.finish();
	} else {
		import std.md5;
		ubyte[16] hash;
		MD5_CTX ctx;
		ctx.start();
		ctx.update(salt);
		foreach( s; strs ) ctx.update(s);
		ctx.finish(hash);
		return hash;
	}
}
