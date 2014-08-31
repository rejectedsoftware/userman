/**
	Database abstraction layer

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.controller;

public import userman.userman;

import vibe.crypto.passwordhash;
import vibe.db.mongo.mongo;
import vibe.http.router;
import vibe.mail.smtp;
import vibe.stream.memory;
import vibe.templ.diet;
import vibe.utils.validation;

import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
import std.random;
import std.string;


class UserManController {
	protected {
		UserManSettings m_settings;
	}
	
	this(UserManSettings settings)
	{	
		m_settings = settings;
	}

	@property UserManSettings settings() { return m_settings; }

	abstract bool isEmailRegistered(string email);

	void validateUser(User usr)
	{
		enforce(usr.name.length > 3, "User names must be at least 3 characters.");
		validateEmail(usr.email);
	}
	
	abstract void addUser(User usr);

	User.ID registerUser(string email, string name, string full_name, string password)
	{
		email = email.toLower();
		name = name.toLower();

		validateEmail(email);
		validatePassword(password, password);

		auto need_activation = m_settings.requireAccountValidation;
		auto user = new User;
		user.active = !need_activation;
		user.name = name;
		user.fullName = full_name;
		user.auth.method = "password";
		user.auth.passwordHash = generateSimplePasswordHash(password);
		user.email = email;
		if( need_activation )
			user.activationCode = generateActivationCode();

		addUser(user);
		
		if( need_activation )
			resendActivation(email);

		return user.id;
	}

	User.ID inviteUser(string email, string full_name, string message)
	{
		email = email.toLower();

		validateEmail(email);

		try {
			return getUserByEmail(email).id;
		}
		catch (Exception e) {
			auto user = new User;
			user.email = email;
			user.name = email;
			user.fullName = full_name;
			addUser(user);

			if( m_settings.mailSettings ){
				auto msg = new MemoryOutputStream;
				parseDietFileCompat!("userman.mail.invitation.dt",
					User, "user",
					string, "serviceName",
					URL, "serviceUrl")(msg,
						user,
						m_settings.serviceName,
						m_settings.serviceUrl);

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
		
		auto msg = new MemoryOutputStream;
		parseDietFileCompat!("userman.mail.activation.dt",
			User, "user",
			string, "serviceName",
			URL, "serviceUrl")(msg,
				user,
				m_settings.serviceName,
				m_settings.serviceUrl);

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
			auto msg = new MemoryOutputStream;
			parseDietFileCompat!("userman.mail.reset_password.dt",
				User*, "user",
				string, "reset_code",
				UserManSettings, "settings")
				(msg, &usr, reset_code, m_settings);

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
		usr.resetCode = "";
		updateUser(usr);
		auto code = usr.resetCode;
		enforce(reset_code == code, "Invalid request code, please request a new one.");
		usr.auth.passwordHash = generateSimplePasswordHash(new_password);
		updateUser(usr);
	}

	abstract User getUser(User.ID id);

	abstract User getUserByName(string name);

	abstract User getUserByEmail(string email);

	abstract User getUserByEmailOrName(string email_or_name);

	abstract void enumerateUsers(int first_user, int max_count, void delegate(ref User usr) del);

	abstract long getUserCount();

	abstract void deleteUser(User.ID user_id);

	abstract void updateUser(User user);

	abstract void addGroup(string name, string description);
}

class User {
	alias .ID!User ID;
	ID id;
	bool active;
	bool banned;
	string name;
	string fullName;
	string email;
	Group.ID[] groups;
	string activationCode;
	string resetCode;
	SysTime resetCodeExpireTime;
	AuthInfo auth;
	Bson[string] properties;
	
	Bson toBson() const
	{
		Bson[string] props;
		props["_id"] = id.bsonObjectIDValue();
		props["active"] = Bson(active);
		props["banned"] = Bson(banned);
		props["name"] = Bson(name);
		props["fullName"] = Bson(fullName);
		props["email"] = Bson(email);
		props["groups"] = serializeToBson(groups);
		props["activationCode"] = Bson(activationCode);
		props["resetCode"] = Bson(resetCode);
		props["resetCodeExpireTime"] = BsonDate(resetCodeExpireTime);
		props["auth"] = serializeToBson(auth);
		props["properties"] = serializeToBson(properties);

		return Bson(props);
	}

	static User fromBson(Bson src)
	{
		auto usr = new User;
		usr.id = User.ID(src["_id"].get!BsonObjectID());
		usr.active = src["active"].get!bool;
		usr.banned = src["banned"].get!bool;
		usr.name = src["name"].get!string;
		usr.fullName = src["fullName"].get!string;
		usr.email = src["email"].get!string;
		usr.groups = deserializeBson!(Group.ID[])(src["groups"]);
		usr.activationCode = src["activationCode"].get!string;
		usr.resetCode = src["resetCode"].get!string;
		usr.resetCodeExpireTime = src["resetCodeExpireTime"].get!BsonDate().toSysTime();
		usr.auth = deserializeBson!AuthInfo(src["auth"]);
		usr.properties = deserializeBson!(Bson[string])(src["properties"]);

		return usr;
	}

	bool isInGroup(string name) const { return groups.countUntil(name) >= 0; }
}

struct AuthInfo {
	string method = "password";
	string passwordHash;
	string token;
	string secret;
	string info;
}

class Group {
	alias .ID!Group ID;
	ID id;
	string name;
	string description;

	Bson toBson() const
	{
		Bson[string] props;
		props["_id"] = id.bsonObjectIDValue();
		props["name"] = name;
		props["description"] = description;

		return Bson(props);
	}

	static Group fromBson(Bson src)
	{
		auto grp = new Group;
		grp.id = Group.ID(src["_id"].get!BsonObjectID());
		grp.name = src["name"].get!string;
		grp.description = src["description"].get!string;
		
		return grp;
	}
}

struct ID(KIND)
{
	import std.conv;

	alias Kind = KIND;

	private {
		union {
			long m_long;
			BsonObjectID m_bsonObjectID;
		}
		IDType m_type;
	}

	alias toString this;

	this(long id) { this = id; }
	this(BsonObjectID id) { this = id; }

	@property BsonObjectID bsonObjectIDValue() const { assert(m_type == IDType.bsonObjectID); return m_bsonObjectID; }
	@property long longValue() const { assert(m_type == IDType.long_); return m_long; }

	void opAssign(long id) { m_type = IDType.long_; m_long = id; }
	void opAssign(BsonObjectID id) { m_type = IDType.bsonObjectID; m_bsonObjectID = id; }
	void opAssign(ID id)
	{
		final switch (id.m_type) {
			case IDType.long_: this = id.m_long; break;
			case IDType.bsonObjectID: this = id.m_bsonObjectID; break;
		}
	}

	static ID fromBson(Bson id) { return ID(id.get!BsonObjectID); }
	Bson toBson() const { assert(m_type == IDType.bsonObjectID); return Bson(m_bsonObjectID); }

	static ID fromLong(long id) { return ID(id); }
	long toLong() const { assert(m_type == IDType.long_); return m_long; }

	static ID fromString(string str)
	{
		if (str.length == 24) return ID(BsonObjectID.fromString(str));
		else return ID(str.to!long);
	}

	string toString()
	const {
		final switch (m_type) {
			case IDType.long_: return m_long.to!string;
			case IDType.bsonObjectID: return m_bsonObjectID.toString();
		}
	}
}

static assert(isBsonSerializable!(ID!void));
unittest {
	assert(serializeToBson(ID!void(BsonObjectID.init)).type == Bson.Type.objectID);
}

enum IDType {
	long_,
	bsonObjectID
}
		

string generateActivationCode()
{
	auto ret = appender!string();
	foreach( i; 0 .. 10 ){
		auto n = cast(char)uniform(0, 62);
		if( n < 26 ) ret.put(cast(char)('a'+n));
		else if( n < 52 ) ret.put(cast(char)('A'+n-26));
		else ret.put(cast(char)('0'+n-52));
	}
	return ret.data();
}
