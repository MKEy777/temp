#pragma once

#include "event_demultiplexer.h"

class EventHandler {
public:
    virtual ~EventHandler() {}
    virtual Handle get_handle() const = 0;//返回它关联的socket
    virtual void handle_read() = 0;
    virtual void handle_write() = 0;
    virtual void handle_error() = 0;
    virtual void handle_close() = 0;
};

