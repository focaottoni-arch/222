# Ottoni — pacote final para GitHub + Netlify + Supabase

## O que foi feito
- Cadastro usando **Gmail real**.
- Login usando o mesmo Gmail e senha.
- Mensagem clara quando o e-mail ainda não foi confirmado.
- Perfil criado automaticamente no Supabase quando uma conta é criada.
- Busca de usuários reais por nome/username.
- Solicitações de amizade reais no Supabase, sem adicionar amizade automaticamente.
- Caixa de notificações com aceitar/recusar.
- Amizade criada nos dois sentidos ao aceitar.
- Criação de grupos em transação, com criador como administrador e membro.
- Convite de amigos para grupos.
- Edição de nome, username e foto do perfil.
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
