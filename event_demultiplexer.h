#pragma once
#include <map>

// Linux/POSIX 平台专用的头文件和类型定义
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>

typedef int Handle;
const int INVALID_SOCKET = -1;
const int SOCKET_ERROR = -1;

enum Event { READ = 0x1, WRITE = 0x2, ERROR = 0x4 };

class EventHandler;

class EventDemultiplexer {
public:
    virtual ~EventDemultiplexer() {}
    virtual int wait_event(std::map<Handle, EventHandler*>& handlers, int timeout = 0) = 0;
    virtual bool regist(Handle handle, Event evt) = 0;
    virtual bool remove(Handle handle) = 0;
};