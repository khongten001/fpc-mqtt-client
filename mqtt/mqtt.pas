{ MQTT Client component for Free Pascal

  Copyright (C) 2022 Bernd Kreuß prof7bit@gmail.com

  This library is free software; you can redistribute it and/or modify it
  under the terms of the GNU Library General Public License as published by
  the Free Software Foundation; either version 2 of the License, or (at your
  option) any later version with the following modification:

  As a special exception, the copyright holders of this library give you
  permission to link this library with independent modules to produce an
  executable, regardless of the license terms of these independent modules,and
  to copy and distribute the resulting executable under terms of your choice,
  provided that you also meet, for each linked independent module, the terms
  and conditions of the license of that module. An independent module is a
  module which is not derived from or based on this library. If you modify
  this library, you may extend this exception to your version of the library,
  but you are not obligated to do so. If you do not wish to do so, delete this
  exception statement from your version.

  This program is distributed in the hope that it will be useful, but WITHOUT
  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU Library General Public License
  for more details.

  You should have received a copy of the GNU Library General Public License
  along with this library; if not, write to the Free Software Foundation,
  Inc., 51 Franklin Street - Fifth Floor, Boston, MA 02110-1335, USA.
}
unit mqtt;

{$mode ObjFPC}{$H+}
{$ModeSwitch arrayoperators}

interface

uses
  Classes, sysutils, Sockets, SSockets, syncobjs, mqttinternal, fptimer;

const
  MQTTDefaultKeepalive: UInt16 = 120; // seconds

  HOUR = 1 / 24;
  MINUTE = HOUR / 60;
  SECOND = MINUTE / 60;

type
  TMQTTError = (
    mqeNoError = 0,
    mqeAlreadyConnected = 1,
    mqeNotConnected = 2,
    mqeHostNotFound = 3,
    mqeConnectFailed = 4,
    mqeMissingHandler = 5,
    mqeAlreadySubscribed = 6,
    mqeEmptyTopic = 7,
    mqeNotSubscribed = 8
  );

  TMQTTClient = class;
  TMQTTDebugFunc = procedure(Txt: String) of object;
  TMQTTDisconnectFunc = procedure(AClient: TMQTTClient) of object;
  TMQTTRXFunc = procedure(AClient: TMQTTClient; ATopic, AMessage: String) of object;

  TMQTTSubscriptionInfo = record
    Topic: String;
    Handler: TMQTTRXFunc;
  end;

  TMQTTRXData = record
    Topic: String;
    Message: String;
    Handler: TMQTTRXFunc;
  end;

  { TMQTTLIstenThread }

  TMQTTLIstenThread = class(TThread)
  protected
    Client: TMQTTClient;
    procedure Execute; override;
  public
    constructor Create(AClient: TMQTTClient); reintroduce;
  end;

  { TMQTTClient }

  TMQTTClient = class(TComponent)
  protected
    FListenThread: TMQTTLIstenThread;
    FSocket: TInetSocket;
    FClosing: Boolean;
    FOnDebug: TMQTTDebugFunc;
    FOnDisconnect: TMQTTDisconnectFunc;
    FSubscriptions: array of TMQTTSubscriptionInfo;
    FRXQueue: array of TMQTTRXData;
    FDebugTxt: String;
    FLock: TCriticalSection;
    FListenWake: TEvent;
    FKeepalive: UInt16;
    FLastPing: TDateTime;
    FKeepaliveTimer: TFPTimer;
    FNextPacketID: UInt16;
    procedure DebugSync;
    procedure Debug(Txt: String);
    procedure Debug(Txt: String; Args: array of const);
    procedure PushOnDisconnect;
    procedure PopOnDisconnect;
    procedure PushOnRX(ATopic, AMessage: String);
    procedure popOnRX;
    procedure OnTimer(Sender: TObject);
    procedure Handle(P: TMQTTConnAck);
    procedure Handle(P: TMQTTPingResp);
    procedure Handle(P: TMQTTSubAck);
    procedure Handle(P: TMQTTPublish);
    function GetNewPacketID: UInt16;
    function ConnectSocket(Host: String; Port: Word): TMQTTError;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function Connect(Host: String; Port: Word; ID, User, Pass: String): TMQTTError;
    function Disconect: TMQTTError;
    function Subscribe(ATopic: String; AHandler: TMQTTRXFunc): TMQTTError;
    function Unsubscribe(ATopic: String): TMQTTError;
    function Publish(ATopic, AMessage: String): TMQTTError;
    function Connected: Boolean;
    property OnDebug: TMQTTDebugFunc read FOnDebug write FOnDebug;
    property OnDisconnect: TMQTTDisconnectFunc read FOnDisconnect write FOnDisconnect;
  end;

implementation

{ TMQTTLIstenThread }

procedure TMQTTLIstenThread.Execute;
var
  P: TMQTTParsedPacket;
begin
  repeat
    if Client.Connected then begin
      try
        P := Client.FSocket.ReadMQTTPacket;
        // Client.Debug('RX: %s %s', [P.ClassName, P.DebugPrint(True)]);
        if      P is TMQTTConnAck  then Client.Handle(P as TMQTTConnAck)
        else if P is TMQTTPingResp then Client.Handle(P as TMQTTPingResp)
        else if P is TMQTTSubAck   then Client.Handle(P as TMQTTSubAck)
        else if P is TMQTTPublish  then Client.Handle(P as TMQTTPublish)
        else begin
          Client.Debug('RX: unknown packet type %d flags %d', [P.PacketType, P.PacketFlags]);
          Client.Debug('RX: data %s', [P.DebugPrint(True)]);
        end;
        P.Free;
      except
        on E: Exception do begin
          Client.Debug('%s: %s', [E.ClassName, E.Message]);
          Client.Disconect;
        end;
      end;
    end
    else
      Client.FListenWake.WaitFor(INFINITE);
  until Terminated;
end;

constructor TMQTTLIstenThread.Create(AClient: TMQTTClient);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  Client := AClient;
  Start;
end;

{ TMQTTClient }

procedure TMQTTClient.DebugSync;
begin
  if Assigned(FOnDebug) then
    FOnDebug(FDebugTxt)
  else
    Writeln(FDebugTxt);
end;

procedure TMQTTClient.Debug(Txt: String);
begin
  if not Assigned(FOnDebug) then
    exit;
  FDebugTxt := Txt;
  TThread.Synchronize(nil, @DebugSync);
end;

procedure TMQTTClient.Debug(Txt: String; Args: array of const);
begin
  if not Assigned(FOnDebug) then
    exit;
  Debug(Format(Txt, Args));
end;

procedure TMQTTClient.PushOnDisconnect;
begin
  TThread.Queue(nil, @PopOnDisconnect);
end;

procedure TMQTTClient.PopOnDisconnect;
begin
  // called from the main thread event loop
  if Assigned(FOnDisconnect) then
    FOnDisconnect(self);
end;

procedure TMQTTClient.PushOnRX(ATopic, AMessage: String);
var
  Data: TMQTTRXData;
  Info: TMQTTSubscriptionInfo;
  Found: Boolean = False;
begin
  FLock.Acquire;
  for Info in FSubscriptions do begin
    if Info.Topic = ATopic then begin
       Found := True;
       break;
    end;
  end;
  if not found then
    FLock.Release
  else begin
    Data.Topic := ATopic;
    Data.Message := AMessage;
    Data.Handler := Info.Handler;
    FRXQueue := [Data] + FRXQueue;
    FLock.Release;
    TThread.Queue(nil, @popOnRX);
  end;
end;

procedure TMQTTClient.popOnRX;
var
  I: Integer;
  Data: TMQTTRXData;
begin
  // called from the main thread event loop
  FLock.Acquire;
  I := Length(FRXQueue) - 1;
  if I < 0 then
    FLock.Release
  else begin
    Data := FRXQueue[I];
    SetLength(FRXQueue, I);
    FLock.Release;
    if Assigned(Data.Handler) then
      Data.Handler(Self, Data.Topic, Data.Message);
  end;
end;

procedure TMQTTClient.OnTimer(Sender: TObject);
begin
  if Connected then begin
    if Now - FLastPing > FKeepalive * SECOND then begin
      Debug('ping');
      FSocket.WriteMQTTPingReq;
      FLastPing := Now;
    end;
  end;
end;

procedure TMQTTClient.Handle(P: TMQTTConnAck);
begin
  if P.ServerKeepalive < FKeepalive then
    FKeepalive := P.ServerKeepalive;
  Debug('keepalive is %d seconds', [FKeepalive]);
  Debug('connected.');
end;

procedure TMQTTClient.Handle(P: TMQTTPingResp);
begin
  Debug('pong');
end;

procedure TMQTTClient.Handle(P: TMQTTSubAck);
var
  B: Byte;
  S: String;
begin
  Debug('suback PacketID: %d', [P.PacketID]);
  Debug('suback ReasonString: ' + P.ReasonString);
  S := 'suback ReasonCodes: ';
  for B in P.ReasonCodes do begin
    S += IntToHex(B, 2) + ' ';
  end;
  Debug(S)
end;

procedure TMQTTClient.Handle(P: TMQTTPublish);
begin
  Debug('publish: topic: %s msg: %s', [P.TopicName, P.Message]);
end;

function TMQTTClient.GetNewPacketID: UInt16;
begin
  FLock.Acquire;
  Result := FNextPacketID;
  if Result = 0 then // IDs must be non-zero, so we skip the zero
    Result := 1;
  FNextPacketID := Result + 1;
  FLock.Release;
end;

function TMQTTClient.ConnectSocket(Host: String; Port: Word): TMQTTError;
begin
  if Connected then
    Result := mqeAlreadyConnected
  else begin
    FClosing := False;
    try
      FSocket := TInetSocket.Create(Host, Port);
      FListenWake.SetEvent;
      Result := mqeNoError;
    except
      on E: ESocketError do begin
        if E.Code = seHostNotFound then
          Result := mqeHostNotFound
        else
          Result := mqeConnectFailed;
        FSocket := nil;
      end;
    end;
  end;
end;

constructor TMQTTClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  FListenWake := TEventObject.Create(nil, False, False, '');
  FSocket := nil;
  FListenThread := TMQTTLIstenThread.Create(Self);
  FKeepaliveTimer := TFPTimer.Create(Self);
  FKeepaliveTimer.OnTimer := @OnTimer;
  FKeepaliveTimer.Interval := 1000;
  FKeepaliveTimer.Enabled := True;
end;

destructor TMQTTClient.Destroy;
begin
  FLock.Acquire;
  FSubscriptions := [];
  FRXQueue := [];
  FOnDisconnect := nil;
  FLock.Release;
  FListenThread.Terminate;
  FListenWake.SetEvent;
  if Connected then
    Disconect;
  FListenThread.WaitFor;
  FreeAndNil(FLock);
  FreeAndNil(FListenWake);
  inherited Destroy;
end;

function TMQTTClient.Connect(Host: String; Port: Word; ID, User, Pass: String): TMQTTError;
begin
  Result := ConnectSocket(Host, Port);
  if Result = mqeNoError then begin
    FKeepalive := MQTTDefaultKeepalive;
    FSocket.WriteMQTTConnect(ID, User, Pass, FKeepalive);
    FLastPing := Now;
  end;
end;

function TMQTTClient.Disconect: TMQTTError;
begin
  if not Connected then
    exit(mqeNotConnected);

  FClosing := True;
  fpshutdown(FSocket.Handle, SHUT_RDWR);
  FreeAndNil(FSocket);
  FLock.Acquire;
  FRXQueue := [];
  FSubscriptions := [];
  FLock.Release;
  PushOnDisconnect;
  Result := mqeNoError;
end;

function TMQTTClient.Subscribe(ATopic: String; AHandler: TMQTTRXFunc): TMQTTError;
var
  Found: Boolean = False;
  Info: TMQTTSubscriptionInfo;
begin
  if not Assigned(AHandler) then
    exit(mqeMissingHandler);
  if ATopic = '' then
    exit(mqeEmptyTopic);
  if not Connected then
    exit(mqeNotConnected);

  Result := mqeNoError;
  FLock.Acquire;
  for Info in FSubscriptions do begin
    if ATopic = Info.Topic then begin
      Found := True;
      break;
    end;
  end;
  FLock.Release;
  if Found then
    exit(mqeAlreadyConnected);

  FSocket.WriteMQTTSubscribe(ATopic, GetNewPacketID);

  Info.Topic := ATopic;
  Info.Handler := AHandler;
  FLock.Acquire;
  FSubscriptions := FSubscriptions + [Info];
  FLock.Release;
end;

function TMQTTClient.Unsubscribe(ATopic: String): TMQTTError;
var
  Found: Boolean = False;
  Info: TMQTTSubscriptionInfo;
  I: Integer = 0;
begin
  Result := mqeNoError;
  FLock.Acquire;
  for Info in FSubscriptions do begin
    if ATopic = Info.Topic then begin
      Found := True;
      break;
    end;
    Inc(I);
  end;
  if not Found then begin
    FLock.Release;
    exit(mqeNotSubscribed);
  end;

  Delete(FSubscriptions, I, 1);
  FLock.Release;

  // todo: implement unsubscribe
end;

function TMQTTClient.Publish(ATopic, AMessage: String): TMQTTError;
begin
  if not Connected then
    exit(mqeNotConnected);

  Result := mqeNoError;
  // todo: implement publish
end;

function TMQTTClient.Connected: Boolean;
begin
  Result := Assigned(FSocket) and not FClosing;
end;


end.

