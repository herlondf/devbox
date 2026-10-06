unit Devbox.Secrets;

{ Chave da IA no Windows Credential Manager (credencial genérica).
  Nada de token em SQLite, JSON ou log. }

interface

procedure SaveSecret(const ATarget, AUser, ASecret: string);
function LoadSecret(const ATarget: string): string;
procedure DeleteSecret(const ATarget: string);

implementation

uses
  Winapi.Windows,
  System.SysUtils;

type
  PCREDENTIALW = ^CREDENTIALW;
  CREDENTIALW = record
    Flags: DWORD;
    Type_: DWORD;
    TargetName: PWideChar;
    Comment: PWideChar;
    LastWritten: TFileTime;
    CredentialBlobSize: DWORD;
    CredentialBlob: PByte;
    Persist: DWORD;
    AttributeCount: DWORD;
    Attributes: Pointer;
    TargetAlias: PWideChar;
    UserName: PWideChar;
  end;

const
  CRED_TYPE_GENERIC = 1;
  CRED_PERSIST_LOCAL_MACHINE = 2;

function CredWriteW(Credential: PCREDENTIALW; Flags: DWORD): BOOL; stdcall;
  external advapi32 name 'CredWriteW';
function CredReadW(TargetName: PWideChar; Type_, Flags: DWORD;
  var Credential: PCREDENTIALW): BOOL; stdcall;
  external advapi32 name 'CredReadW';
function CredDeleteW(TargetName: PWideChar; Type_, Flags: DWORD): BOOL; stdcall;
  external advapi32 name 'CredDeleteW';
procedure CredFree(Buffer: Pointer); stdcall;
  external advapi32 name 'CredFree';

procedure SaveSecret(const ATarget, AUser, ASecret: string);
var
  C: CREDENTIALW;
  Blob: TBytes;
begin
  Blob := TEncoding.UTF8.GetBytes(ASecret);
  FillChar(C, SizeOf(C), 0);
  C.Type_ := CRED_TYPE_GENERIC;
  C.TargetName := PWideChar(ATarget);
  C.UserName := PWideChar(AUser);
  C.CredentialBlobSize := Length(Blob);
  if Length(Blob) > 0 then
    C.CredentialBlob := @Blob[0];
  C.Persist := CRED_PERSIST_LOCAL_MACHINE;
  if not CredWriteW(@C, 0) then
    RaiseLastOSError;
end;

function LoadSecret(const ATarget: string): string;
var
  C: PCREDENTIALW;
  Blob: TBytes;
begin
  Result := '';
  if not CredReadW(PWideChar(ATarget), CRED_TYPE_GENERIC, 0, C) then
    Exit;
  try
    SetLength(Blob, C.CredentialBlobSize);
    if C.CredentialBlobSize > 0 then
      Move(C.CredentialBlob^, Blob[0], C.CredentialBlobSize);
    Result := TEncoding.UTF8.GetString(Blob);
  finally
    CredFree(C);
  end;
end;

procedure DeleteSecret(const ATarget: string);
begin
  CredDeleteW(PWideChar(ATarget), CRED_TYPE_GENERIC, 0);
end;

end.
