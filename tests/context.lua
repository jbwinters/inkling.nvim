-- nvim --headless -u NONE -l tests/context.lua
-- Builds small fixture projects and checks upstream / peer / downstream context.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
local gw = require("inkling")
gw.setup({ context = { project = { small_file_chars = 200 } } })
local project = require("inkling.context.project")

local failures = 0
local function check(name, cond, info)
  print((cond and "ok   " or "FAIL ") .. name .. (info and ("  " .. info) or ""))
  if not cond then failures = failures + 1 end
end

local tmp = vim.fn.tempname()
local function write(rel, text)
  local p = tmp .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(p), "p")
  vim.fn.writefile(vim.split(text, "\n"), p)
end

local function context_for(rel)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/" .. rel))
  local done, text, summary = false
  project.build(vim.api.nvim_get_current_buf(), function(t, s) text, summary, done = t, s, true end)
  vim.wait(5000, function() return done end, 20)
  return text or "", table.concat(summary or {}, "\n")
end

-- Python -------------------------------------------------------------------
vim.fn.mkdir(tmp .. "/.git", "p")
write("app/models.py", [[
from dataclasses import dataclass

MAX_USERS = 100

@dataclass
class User:
    id: int
    name: str

    def display(self) -> str:
        return f"{self.name} ({self.id})"


def load_user(user_id: int,
              strict: bool = False) -> User:
    """Load a user from the database."""
    row = db.fetch(user_id)
    return User(row.id, row.name)


def _private_helper():
    pass
]])
write("app/service.py", [[
from .models import User, load_user


def greet(user_id):
    user = load_user(user_id)
    return "hi " + user.display()
]])
write("api/views.py", [[
import json
from app.service import greet

def index(request):
    return json.dumps({"msg": greet(request.user_id)})
]])
local text, summary = context_for("app/service.py")
print(summary)
check("py upstream models.py", text:find("app/models.py %(imported") ~= nil)
check("py outline has class", text:find("class User:") ~= nil)
check("py outline joins multiline sig", text:find("strict: bool = False%) %-> User:") ~= nil)
check("py definition of load_user included", text:find("Load a user from the database") ~= nil)
check("py definition of User includes method body", text:find('return f"{self.name}') ~= nil)
check("py private def excluded from definitions", select(2, text:gsub("_private_helper", "")) == 1, "(outline only)")
check("py downstream views.py", text:find("api/views.py %(imports the current file") ~= nil)
check("py downstream shows usage", text:find('greet%(request.user_id%)') ~= nil)

-- Elixir -------------------------------------------------------------------
write("mix.exs", "defmodule MyApp.MixProject do\nend")
write("lib/my_app/accounts.ex", [[
defmodule MyApp.Accounts do
  alias MyApp.Accounts.User
  alias MyApp.Repo

  @spec get_user!(integer()) :: User.t()
  def get_user!(id) do
    Repo.get!(User, id)
  end

  def list_users, do: Repo.all(User)

  defp secret, do: :ok
end
]])
write("lib/my_app/accounts/user.ex", [[
defmodule MyApp.Accounts.User do
  use Ecto.Schema

  schema "users" do
    field :name, :string
    field :email, :string
    has_many :posts, MyApp.Blog.Post
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
  end
end
]])
write("lib/my_app_web/user_controller.ex", [[
defmodule MyAppWeb.UserController do
  alias MyApp.Accounts

  def show(conn, %{"id" => id}) do
    user = Accounts.get_user!(id)
    render(conn, :show, user: user)
  end
end
]])
text, summary = context_for("lib/my_app/accounts.ex")
print(summary)
check("ex upstream user.ex", text:find("lib/my_app/accounts/user.ex") ~= nil)
check("ex schema fields in outline", text:find('field :email, :string') ~= nil)
check("ex downstream controller", text:find("user_controller.ex %(imports") ~= nil)
check("ex downstream usage", text:find("Accounts.get_user!%(id%)") ~= nil)

-- TypeScript -----------------------------------------------------------------
write("web/src/api.ts", [[
export interface Todo {
  id: number
  title: string
}

export async function fetchTodos(limit: number): Promise<Todo[]> {
  const res = await fetch(`/api/todos?limit=${limit}`)
  return res.json()
}

export class TodoClient {
  constructor(private base: string) {}

  async get(id: number): Promise<Todo> {
    if (id < 0) {
      throw new Error("bad id")
    }
    return fetch(this.base + id).then((r) => r.json())
  }
}
]])
write("web/src/App.tsx", [[
import { fetchTodos, type Todo } from './api'

export function App() {
  const todos: Todo[] = []
  fetchTodos(10)
}
]])
text, summary = context_for("web/src/App.tsx")
print(summary)
check("ts upstream api.ts", text:find("web/src/api.ts %(imported") ~= nil)
check("ts definition fetchTodos", text:find("const res = await fetch") ~= nil)
check("ts method in outline", text:find("async get%(id: number%)") ~= nil)
check("ts no `if` as method", text:find("if %(id < 0%) {\n```") == nil)

if os.getenv("SHOW") then text = context_for("app/service.py"); print("\n" .. text) end
vim.fn.delete(tmp, "rf")
os.exit(failures == 0 and 0 or 1)
