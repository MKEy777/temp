#pragma once
#include "reactor.h"
#include "event_demultiplexer.h"
#include "event_handler.h"
#include <mutex>

class ReactorImplementation {
private:
	EventDemultiplexer* demux;// �¼��ַ���
	std::map<Handle, EventHandler*> handlers;// ������¼���������ӳ��
	std::mutex handlers_mutex;

public:
    // ���캯����������������
    ReactorImplementation();
    ~ReactorImplementation();

    // ��Ա��������
    void regist(EventHandler* handler, Event evt);
    void remove(Handle fd);
    void modify(Handle fd, Event evt);
    //���ϵ��� demux->wait_event()��Ȼ�󴥷���Ӧ�Ļص�
    void event_loop(int timeout);
};

Reactor::Reactor() : impl(new ReactorImplementation()) {}
Reactor::~Reactor() { delete impl; }
void Reactor::regist(EventHandler* handler, Event evt) { impl->regist(handler, evt); }
void Reactor::remove(Handle fd) { impl->remove(fd); }
void Reactor::modify(Handle fd, Event evt) { impl->modify(fd, evt); }
void Reactor::event_loop(int timeout) { impl->event_loop(timeout); }