#include "networkmanager.h"
#include <QHostAddress>
#include <QNetworkProxy>

NetworkManager::NetworkManager(QObject *parent) : QObject(parent)
{
    socket_ = new QTcpSocket(this);
    connect(socket_, &QTcpSocket::stateChanged, this, &NetworkManager::on_socket_state_changed);
    connect(socket_, &QTcpSocket::readyRead, this, &NetworkManager::on_ready_read);
    //connect(socket_, &QAbstractSocket::errorOccurred, this, &NetworkManager::on_socket_error);
    connect(socket_, SIGNAL(error(QAbstractSocket::SocketError)),
            this, SLOT(on_socket_error(QAbstractSocket::SocketError)));
}

void NetworkManager::connect_to_server(const QString& ip, quint16 port)
{
    socket_->setProxy(QNetworkProxy::NoProxy);
    socket_->connectToHost(QHostAddress(ip), port);
}

void NetworkManager::disconnect_from_server()
{
    socket_->disconnectFromHost();
}

void NetworkManager::send_login_request(const QString& username)
{
    QJsonObject json;
    json["type"] = "login_request";
    json["username"] = username;
    send_json(json);
}

void NetworkManager::send_chat_message(const QString& text)
{
    QJsonObject json;
    json["type"] = "chat_message";
    json["text"] = text;
    send_json(json);
}

void NetworkManager::send_json(const QJsonObject& json)
{
    if (socket_->state() == QAbstractSocket::ConnectedState) {
        // 将JSON对象转换为紧凑的字符串，并添加换行符作为分隔符
        QByteArray data = QJsonDocument(json).toJson(QJsonDocument::Compact) + "\n";
        socket_->write(data);
    }
}

void NetworkManager::on_socket_state_changed(QAbstractSocket::SocketState socketState)
{
    if (socketState == QAbstractSocket::ConnectedState) {
        emit connected();
    } else if (socketState == QAbstractSocket::UnconnectedState) {
        emit disconnected();
    }
}

void NetworkManager::on_socket_error(QAbstractSocket::SocketError socketError)
{
    emit connection_error(socket_->errorString());
}

void NetworkManager::on_ready_read()
{
    // 追加新数据到缓冲区
    buffer_.append(socket_->readAll());

    // 循环处理，直到缓冲区中没有完整的消息
    while (buffer_.contains('\n')) {
        int newline_pos = buffer_.indexOf('\n');
        QByteArray json_data = buffer_.left(newline_pos);
        buffer_.remove(0, newline_pos + 1); // 移除已处理的消息和换行符

        QJsonDocument doc = QJsonDocument::fromJson(json_data);
        if (!doc.isObject()) continue;

        QJsonObject json = doc.object();
        QString type = json["type"].toString();

        if (type == "chat_message") {
            QString username = json["username"].toString();
            QString text = json["text"].toString();
            emit chat_message_received(username, text);
        } else if (type == "system_notification") {
            QString message = json["message"].toString();
            emit system_notification_received(message);
        } else if (type == "user_list_update") {
            QJsonArray users_array = json["users"].toArray();
            QStringList users;
            for (const QJsonValue &value : users_array) {
                users.append(value.toString());
            }
            emit user_list_updated(users);
        }
    }
}
