#pragma once

#include <map>
#include <winsock2.h>

typedef SOCKET Handle;

enum Event { READ = 0x1, WRITE = 0x2, ERROR = 0x4 };

class EventHandler;  // Ç°ÏòÉùÃ÷

class EventDemultiplexer {
public:
    virtual ~EventDemultiplexer() {}
    virtual int wait_event(std::map<Handle, EventHandler*>& handlers, int timeout = 0) = 0;
    virtual bool regist(Handle handle, Event evt) = 0;
    virtual bool remove(Handle handle) = 0;
};
