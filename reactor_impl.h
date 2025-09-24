#pragma once
#include "reactor.h"
#include "event_demultiplexer.h"
#include "event_handler.h"
#include <mutex>

class ReactorImplementation {
private:
	EventDemultiplexer* demux;// 事件分发器
	std::map<Handle, EventHandler*> handlers;// 句柄到事件处理器的映射
	std::mutex handlers_mutex;

public:
    // 构造函数和析构函数声明
    ReactorImplementation();
    ~ReactorImplementation();

    // 成员函数声明
    void regist(EventHandler* handler, Event evt);
    void remove(Handle fd);
    void modify(Handle fd, Event evt);
    //不断调用 demux->wait_event()，然后触发相应的回调
    void event_loop(int timeout);
};

Reactor::Reactor() : impl(new ReactorImplementation()) {}
Reactor::~Reactor() { delete impl; }
void Reactor::regist(EventHandler* handler, Event evt) { impl->regist(handler, evt); }
void Reactor::remove(Handle fd) { impl->remove(fd); }
void Reactor::modify(Handle fd, Event evt) { impl->modify(fd, evt); }
void Reactor::event_loop(int timeout) { impl->event_loop(timeout); }