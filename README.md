# Ottoni — pacote final para GitHub + Netlify + Supabase

## O que foi feito
- Cadastro usando **Gmail real**.
- Login usando o mesmo Gmail e senha.
- Mensagem clara quando o e-mail ainda não foi confirmado.
- Perfil criado automaticamente no Supabase quando uma conta é criada.
- Usuários cadastrados aparecem na busca de **Adicionar amigo**.
- Busca de amigos por nome/usuário e também aceitando o Gmail como atalho para o nome de usuário.
- IA continua em `POST /api/analisar`, executada por uma Netlify Function.
- A chave da OpenAI fica somente em variável de ambiente.
- Layout/CSS do site original preservado.

## 1) Supabase
Abra **SQL Editor** e execute `supabase_revisado_gmail_amigos.sql`.

Depois, em **Authentication → Providers → Email**, mantenha o login por e-mail ativo. Para receber o e-mail de confirmação, mantenha **Confirm email** ativado.

Para personalizar o e-mail que o usuário recebe:
- Abra **Authentication → Email Templates → Confirm signup**.
- Use o arquivo `SUPABASE_EMAIL_TEMPLATE.html` como corpo do e-mail.
- O link `{{ .ConfirmationURL }}` deve permanecer no template.

O assunto sugerido é: **Conta criada no Ottoni**.

## 2) GitHub
Envie os arquivos e pastas deste pacote para o repositório, mantendo:

```text
index.html
netlify.toml
package.json
SUPABASE_EMAIL_TEMPLATE.html
supabase_revisado_gmail_amigos.sql
netlify/functions/analisar.mjs
```

## 3) Netlify
Conecte o repositório do GitHub à Netlify.

Em **Project configuration → Environment variables**, crie:

```text
OPENAI_API_KEY = sua_chave_da_OpenAI
```

Opcionalmente:

```text
OPENAI_MODEL = gpt-4o-mini
```

Faça um novo deploy depois de salvar as variáveis.

## 4) Importante sobre o login
Quando a confirmação de e-mail estiver ativada, o usuário pode criar a conta e receber o e-mail, mas só conseguirá fazer login depois de clicar no link de confirmação.

Se o Supabase estiver com o limite de cadastro temporariamente atingido, o arquivo não consegue remover esse bloqueio; é necessário aguardar a janela do limite passar.

## 5) Segurança
Nunca coloque `OPENAI_API_KEY` dentro do `index.html`. Ela deve ficar apenas nas variáveis de ambiente da Netlify.

## Correções de banco e amigos/grupos

O arquivo `supabase_revisado_gmail_amigos.sql` foi atualizado para:
- pesquisar usuários reais por username/nome via RPC;
- enviar, aceitar e recusar solicitações de amizade;
- criar as duas relações de amizade ao aceitar;
- criar grupos de forma atômica usando o usuário autenticado;
- adicionar automaticamente o criador como membro;
- adicionar membros reais ao grupo;
- manter mensagens e Realtime.

Depois de substituir os arquivos no mesmo repositório, execute **o arquivo SQL inteiro** no SQL Editor do mesmo projeto Supabase.

