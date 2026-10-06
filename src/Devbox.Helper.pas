unit Devbox.Helper;

{ Conversa entre o Devbox.exe e o DevboxHelper.exe (expansor e captura). O
  ajudante tem uma janela escondida com legenda própria da pasta de dados;
  quem quer falar com ele acha a janela e manda uma mensagem registrada. }

interface

uses
  Winapi.Windows;

const
  HelperExeName = 'DevboxHelper.exe';
  HelperClassName = 'THelperForm';

var
  WM_HELPER_RELOAD: Cardinal;    // releia atalhos e preferências do banco
  WM_HELPER_CAPTURE: Cardinal;   // comece uma captura de tela
  WM_HELPER_QUIT: Cardinal;      // feche (o Devbox está saindo)

{ Legenda da janela do ajudante: muda com a pasta de dados, para a instância
  de teste não conversar com a do dia a dia. }
function HelperCaption: string;

function HelperWindow: HWND;

{ False se o ajudante não está rodando. }
function PostToHelper(AMsg: Cardinal): Boolean;

{ Abre o ajudante ao lado do exe (se ainda não está aberto). False = não achou. }
function StartHelper: Boolean;

implementation

uses
  System.SysUtils,
  System.Hash,
  Winapi.ShellAPI;

function HelperCaption: string;
begin
  Result := 'DevboxHelper.' + Copy(THashMD5.GetHashString(LowerCase(GetEnvironmentVariable('LOCALAPPDATA'))), 1, 8);
end;

function HelperWindow: HWND;
begin
  Result := FindWindow(HelperClassName, PChar(HelperCaption));
end;

function PostToHelper(AMsg: Cardinal): Boolean;
var
  W: HWND;
begin
  W := HelperWindow;
  Result := W <> 0;
  if Result then
    PostMessage(W, AMsg, 0, 0);
end;

function StartHelper: Boolean;
var
  Exe: string;
begin
  if HelperWindow <> 0 then
    Exit(True);
  Exe := ExtractFilePath(ParamStr(0)) + HelperExeName;
  Result := FileExists(Exe);
  if Result then
    ShellExecute(0, 'open', PChar(Exe), PChar('-parent ' + IntToStr(GetCurrentProcessId)), nil, SW_HIDE);
end;

initialization
  WM_HELPER_RELOAD := RegisterWindowMessage('Devbox.Helper.Reload');
  WM_HELPER_CAPTURE := RegisterWindowMessage('Devbox.Helper.Capture');
  WM_HELPER_QUIT := RegisterWindowMessage('Devbox.Helper.Quit');

end.
