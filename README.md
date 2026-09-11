# Ottoni — pacote final para GitHub + Netlify + Supabase

## O que foi feito
- Cadastro usando **Gmail real**.
- Login usando o mesmo Gmail e senha.
- Mensagem clara quando o e-mail ainda não foi confirmado.
- Perfil criado automaticamente no Supabase quando uma conta é criada.
- Usuários cadastrados aparecem na busca de **Adicionar amigo**.
- Busca de amigos por nome/usuário e também aceitando o Gmail como atalho para o nome de usuário.
- IA continua em `POST /api/analisar`, executada por uma Netlify Function.
- Mensagens humanas e respostas da IA são salvas na tabela `messages` quando há uma sessão e um grupo remoto.
- Grupos são carregados em lista e mensagens ativas usam Supabase Realtime.
- Amizades usam solicitações aceitas, com suporte a bloqueios.
- Fotos de perfil e grupo usam o bucket `ottoni-media` do Supabase Storage quando há login.
- A prévia local limita a IA a 15 análises por dia para a brincadeira não consumir recursos sem querer.
- A chave da OpenAI fica somente em variável de ambiente.
- Layout/CSS do site original preservado.

## 1) Supabase
Abra **SQL Editor** e execute `supabase_revisado_gmail_amigos.sql`.

Esse SQL também libera a gravação de respostas marcadas como IA (`is_ai = true`) dentro de grupos aos quais o usuário autenticado pertence. Execute novamente o arquivo se você já havia instalado uma versão anterior, pois as políticas serão atualizadas.

O mesmo SQL cria as tabelas de solicitações e bloqueios, o bucket público `ottoni-media` e adiciona mensagens à publicação Realtime. Execute o arquivo inteiro novamente no SQL Editor depois destas alterações.

Depois, em **Authentication → Providers → Email**, mantenha o login por e-mail ativo. Para receber o e-mail de confirmação, mantenha **Confirm email** ativado.

Para liberar o botão **Continuar com Google**, abra **Authentication → Providers → Google**, ative o provedor e informe o Client ID e o Client Secret criados no Google Cloud Console. No Google Cloud, adicione a URL de callback exibida pelo Supabase, normalmente:

```text
https://SEU-PROJETO.supabase.co/auth/v1/callback
```

O botão usa automaticamente a URL atual do site como destino após o login.

Em **Authentication → URL Configuration**, configure:

```text
Site URL: https://SEU-DOMINIO.netlify.app
Additional Redirect URLs: https://SEU-DOMINIO.netlify.app/**
```

O site envia automaticamente a URL atual em `emailRedirectTo`. Assim, no deploy o link do Gmail retorna para a URL publicada. Durante o teste local, ele retorna para `http://localhost:4173/`.

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
SUPABASE_URL = https://seu-projeto.supabase.co
SUPABASE_ANON_KEY = sua_chave_publica_do_Supabase
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

A função `/api/analisar` exige uma sessão válida do Supabase. Isso impede que visitantes anônimos usem sua chave da OpenAI diretamente e ajuda a controlar custos. Depois de criar ou alterar essas variáveis, faça um novo deploy.
