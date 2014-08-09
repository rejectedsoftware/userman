/**
	Basic definitions

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.userman;

public import vibe.mail.smtp;
public import vibe.inet.url;

class UserManSettings {
	bool requireAccountValidation = true;
	bool useUserNames = true; // use a user name or the email address for identification?
	string databaseURL = "mongodb://127.0.0.1:27017/test";//*/"redis://127.0.0.1:6379/1";
	string serviceName = "User database test";
	URL serviceUrl = "http://www.example.com/";
	string serviceEmail = "userdb@example.com";
	SMTPClientSettings mailSettings;

	this()
	{
		mailSettings = new SMTPClientSettings;
	}
}
