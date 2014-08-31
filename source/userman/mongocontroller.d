/**
	Database abstraction layer

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.mongocontroller;

import userman.controller;

import vibe.db.mongo.mongo;

import std.string;


class MongoUserManController : UserManController {
	private {
		MongoCollection m_users;
		MongoCollection m_groups;
	}
	
	this(UserManSettings settings)
	{	
		super(settings);

		string database = "admin";
		MongoClientSettings dbSettings;
		if (parseMongoDBUrl(dbSettings, settings.databaseURL))
			database = dbSettings.database;

		auto db = connectMongoDB(settings.databaseURL).getDatabase(database);
		m_users = db["userman.users"];
		m_groups = db["userman.groups"];

		m_users.ensureIndex(["name": 1], IndexFlags.Unique);
		m_users.ensureIndex(["email": 1], IndexFlags.Unique);
	}

	override bool isEmailRegistered(string email)
	{
		auto bu = m_users.findOne(["email": email], ["auth": true]);
		return !bu.isNull() && bu.auth.method.get!string.length > 0;
	}
	
	override User.ID addUser(User usr)
	{
		validateUser(usr);
		enforce(m_users.findOne(["name": usr.name]).isNull(), "The user name is already taken.");
		enforce(m_users.findOne(["email": usr.email]).isNull(), "The email address is already in use.");
		
		usr.id = User.ID(BsonObjectID.generate());
		m_users.insert(usr);

		return usr.id;
	}

	override User getUser(User.ID id)
	{
		auto busr = m_users.findOne(["_id": id.bsonObjectIDValue	]);
		enforce(!busr.isNull(), "The specified user id is invalid.");
		auto ret = new User;
		deserializeBson(ret, busr);
		return ret;
	}

	override User getUserByName(string name)
	{
		name = name.toLower();

		auto busr = m_users.findOne(["name": name]);
		enforce(!busr.isNull(), "The specified user name is not registered.");
		auto ret = new User;
		deserializeBson(ret, busr);
		return ret;
	}

	override User getUserByEmail(string email)
	{
		email = email.toLower();

		auto busr = m_users.findOne(["email": email]);
		enforce(!busr.isNull(), "There is no user account for the specified email address.");
		auto ret = new User;
		deserializeBson(ret, busr);
		return ret;
	}

	override User getUserByEmailOrName(string email_or_name)
	{
		auto busr = m_users.findOne(["$or": [["email": email_or_name.toLower()], ["name": email_or_name]]]);
		enforce(!busr.isNull(), "The specified email address or user name is not registered.");
		auto ret = new User;
		deserializeBson(ret, busr);
		return ret;
	}

	override void enumerateUsers(int first_user, int max_count, void delegate(ref User usr) del)
	{
		foreach( busr; m_users.find(["query": null, "orderby": ["name": 1]], null, QueryFlags.None, first_user, max_count) ){
			if (max_count-- <= 0) break;
			auto usr = deserializeBson!User(busr);
			del(usr);
		}
	}

	override long getUserCount()
	{
		return m_users.count(Bson.emptyObject);
	}

	override void deleteUser(User.ID user_id)
	{
		m_users.remove(["_id": user_id.bsonObjectIDValue]);
	}

	override void updateUser(User user)
	{
		validateUser(user);
		enforce(m_settings.useUserNames || user.name == user.email, "User name must equal email address if user names are not used.");
		// FIXME: enforce that no user names or emails are used twice!

		m_users.update(["_id": user.id.bsonObjectIDValue], user);
	}

	override void setEmail(User.ID user, string email)
	{
		m_users.update(["_id": user.bsonObjectIDValue], ["$set": ["email": email]]);
	}

	override void setFullName(User.ID user, string full_name)
	{
		m_users.update(["_id": user.bsonObjectIDValue], ["$set": ["fullName": full_name]]);
	}

	override void setPassword(User.ID user, string password)
	{
		import vibe.crypto.passwordhash;
		m_users.update(["_id": user.bsonObjectIDValue], ["$set":
			["auth.method": "password", "auth.passwordHash": generateSimplePasswordHash(password)]]);
	}

	override void setProperty(User.ID user, string name, string value)
	{
		m_users.update(["_id": user.bsonObjectIDValue], ["$set": ["properties."~name: value]]);
	}
	
	override void addGroup(string name, string description)
	{
		enforce(m_groups.findOne(["name": name]).isNull(), "A group with this name already exists.");
		auto grp = new Group;
		grp.id = Group.ID(BsonObjectID.generate());
		grp.name = name;
		grp.description = description;
		m_groups.insert(grp);
	}
}
