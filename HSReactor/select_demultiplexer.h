#pragma once
#include "event_demultiplexer.h"

class SelectDemultiplexer : public EventDemultiplexer {
private:
    fd_set read_set;
    fd_set write_set;
    fd_set err_set;

public:
    SelectDemultiplexer();
    ~SelectDemultiplexer() override {}
	int wait_event(std::map<Handle, EventHandler*>& handlers, int timeout = 0) override;// 返回就绪的事件数
    bool regist(Handle handle, Event evt) override;
    bool remove(Handle handle) override;
};