unit SourceRcon;

interface

uses
  System.Types, System.Classes, System.SysUtils, IdTCPClient, IdGlobal;

type
  TSourceRconClient = class
  private type
    TOnMessage = procedure(const aRespID: Integer; const aPayload: string)
      of object;
    TOnConnected = procedure of object;
    TOnDisconnected = procedure of object;
    TOnAuth = procedure(const Success: Boolean) of object;

  private type
    TRconPacketType = (SERVERDATA_RESPONSE_VALUE = 0,
      SERVERDATA_EXECCOMMAND = 1, SERVERDATA_AUTH_RESPONSE = 2,
      SERVERDATA_AUTH = 3);
  private
    fTCPClient: TIdTCPClient;
    fHost: string;
    fPort: Integer;
    fPassword: string;
    fLastConnectError: string;
    // Thread to read responses;
    fReadThread: TThread;
    // Events
    fOnMessage: TOnMessage;
    fOnConnected: TOnConnected;
    fOnDisconnected: TOnDisconnected;
    fOnAuth: TOnAuth;

    procedure DoOnConnected(Sender: TObject);
    procedure DoOnDisconnected(Sender: TObject);
    procedure StartReadThread;
    function SendPacket(const aReqID: Int32; PktType: TRconPacketType;
      const Payload: string): Int32;
    function ReadPacket(var PktType: Integer; var Payload: String): Int32;
  public
    procedure SendCommand(const aID: Int32; const aPayload: string);
    function Connect(const aTimeout: Integer = 10000): Boolean;
    procedure Disconnect;
    constructor Create(aHost: string; aPort: Integer; aPassword: string);
    destructor Destroy; override;
  published
    // Events
    property OnConnected: TOnConnected read fOnConnected write fOnConnected;
    property OnDisconnected: TOnDisconnected read fOnDisconnected
      write fOnDisconnected;
    property OnMessage: TOnMessage read fOnMessage write fOnMessage;
    property OnAuth: TOnAuth read fOnAuth write fOnAuth;
    //
    property Host: string read fHost;
    property Port: Integer read fPort;
    property Password: string read fPassword;
    property LastConnectError: string read fLastConnectError;
  end;

implementation

{ TSourceRconClient }

function TSourceRconClient.Connect(const aTimeout: Integer): Boolean;
begin
  Result := False;

  try
    fTCPClient.ConnectTimeout := aTimeout;

    fTCPClient.Host := fHost;
    fTCPClient.Port := fPort;

    fTCPClient.Connect;

    if fTCPClient.Connected then
      Result := True;
  except
    on E: Exception do
    begin
      fLastConnectError := E.Message;
      Result := False;
    end;
  end;
end;

constructor TSourceRconClient.Create(aHost: string; aPort: Integer;
  aPassword: string);
begin
  fHost := aHost;
  fPort := aPort;
  fPassword := aPassword;

  fTCPClient := TIdTCPClient.Create(nil);
  fTCPClient.OnConnected := DoOnConnected;
  fTCPClient.OnDisconnected := DoOnDisconnected;
end;

destructor TSourceRconClient.Destroy;
begin
  if fTCPClient.Connected then
    fTCPClient.Disconnect;

  fTCPClient.Free;

  inherited;
end;

procedure TSourceRconClient.Disconnect;
begin
  fTCPClient.Disconnect;
end;

procedure TSourceRconClient.DoOnConnected(Sender: TObject);
begin
  StartReadThread;

  // Auth
  SendPacket(0, TRconPacketType.SERVERDATA_AUTH, fPassword);

  if Assigned(fOnConnected) then
    fOnConnected;
end;

procedure TSourceRconClient.DoOnDisconnected(Sender: TObject);
begin
  if Assigned(fOnDisconnected) then
    fOnDisconnected;
end;

function TSourceRconClient.ReadPacket(var PktType: Integer;
  var Payload: String): Int32;
var
  Len: Int32;
begin
  try
    Len := fTCPClient.IOHandler.ReadInt32(False);
    Result := fTCPClient.IOHandler.ReadInt32(False);
    PktType := fTCPClient.IOHandler.ReadInt32(False);
    Payload := fTCPClient.IOHandler.ReadString(Len - 10,
      IndyTextEncoding_UTF8).Trim;
    fTCPClient.IOHandler.Discard(2);
  except
    fTCPClient.Disconnect;
    raise;
  end;
end;

procedure TSourceRconClient.SendCommand(const aID: Int32;
  const aPayload: string);
begin
  SendPacket(aID, TRconPacketType.SERVERDATA_EXECCOMMAND, aPayload);
end;

function TSourceRconClient.SendPacket(const aReqID: Int32;
  PktType: TRconPacketType; const Payload: string): Int32;
var
  Bytes: TIdBytes;
begin

  if not fTCPClient.Connected then
    Exit;

  Bytes := IndyTextEncoding_ASCII.GetBytes(Payload);
  try
    fTCPClient.IOHandler.WriteBufferOpen;
    try
      fTCPClient.IOHandler.Write(Int32(Length(Bytes) + 10), False);
      fTCPClient.IOHandler.Write(aReqID, False);
      fTCPClient.IOHandler.Write(Integer(PktType), False);
      fTCPClient.IOHandler.Write(Bytes);
      fTCPClient.IOHandler.Write(UInt16(0), False);
      fTCPClient.IOHandler.WriteBufferClose;
    except
      fTCPClient.IOHandler.WriteBufferCancel;
      raise;
    end;
  except
    fTCPClient.Disconnect;
    raise;
  end;
end;

procedure TSourceRconClient.StartReadThread;
begin
  fReadThread := TThread.CreateAnonymousThread(
    procedure
    begin
      while fTCPClient.Connected do
      begin
        var
          RespID: Int32;
        var
          PktType: Int32;
        var
          Payload: string;

        try
          if fTCPClient.IOHandler.InputBufferIsEmpty then
          begin
            fTCPClient.IOHandler.CheckForDataOnSource(0);
            fTCPClient.IOHandler.CheckForDisconnect(True, False);
          end;

          if not fTCPClient.IOHandler.InputBufferIsEmpty then
          begin
            RespID := ReadPacket(PktType, Payload);

            var
            aPktType := TRconPacketType(PktType);

            // AuthResponse;
            if aPktType = TRconPacketType.SERVERDATA_AUTH_RESPONSE then
            begin
              if RespID = -1 then
              begin
                // Auth Failed
                if Assigned(fOnAuth) then
                begin
                  TThread.Synchronize(fReadThread,
                    procedure
                    begin
                      fOnAuth(False);
                    end);
                end;
              end
              else
              begin
                // Auth Success
                if Assigned(fOnAuth) then
                begin
                  TThread.Synchronize(fReadThread,
                    procedure
                    begin
                      fOnAuth(True);
                    end);
                end;
              end;
            end;
            // Response from Command
            if aPktType = TRconPacketType.SERVERDATA_RESPONSE_VALUE then
            begin
              Payload := Payload.Trim;

              if Assigned(fOnMessage) then
              begin
                TThread.Synchronize(fReadThread,
                  procedure
                  begin
                    fOnMessage(RespID, Payload);
                  end);
              end;

            end;
          end;
        except
          fTCPClient.Disconnect;
        end;
      end;
    end);

  fReadThread.FreeOnTerminate := True;
  fReadThread.Start;
end;

end.
