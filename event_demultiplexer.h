#pragma once
#include <map>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>

typedef int Handle;//socket 描述符
const int INVALID_SOCKET = -1;
const int SOCKET_ERROR = -1;

enum Event { READ = 0x1, WRITE = 0x2, ERROR = 0x4 };

class EventHandler;

class EventDemultiplexer {
public:
    virtual ~EventDemultiplexer() {}
    //等待事件发生
    virtual int wait_event(std::map<Handle, EventHandler*>& handlers, int timeout = 0) = 0;
	//注册socket、事件
    virtual bool regist(Handle handle, Event evt) = 0;
    //移除socket
    virtual bool remove(Handle handle) = 0;
};