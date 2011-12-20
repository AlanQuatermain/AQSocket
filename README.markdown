# AQSocket
#### Copyright (c) 2011 Jim Dovey. All Rights Reserved.

AQSocket is a simple Objective-C socket class written to make use of dispatch I/O channels on sockets. It uses a CFSocketRef to provide asynchronous connection, and uses dispatch sources and dispatch I/O channels to implement asynchronous read and write operations.