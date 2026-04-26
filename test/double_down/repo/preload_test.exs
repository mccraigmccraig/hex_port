defmodule DoubleDown.Repo.PreloadTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Repo.InMemory
  alias DoubleDown.Repo

  # -------------------------------------------------------------------
  # Test schemas with associations
  # -------------------------------------------------------------------

  defmodule Author do
    use Ecto.Schema

    schema "authors" do
      field(:name, :string)
      has_many(:posts, DoubleDown.Repo.PreloadTest.Post)
      has_one(:profile, DoubleDown.Repo.PreloadTest.Profile)
    end
  end

  defmodule Post do
    use Ecto.Schema

    schema "posts" do
      field(:title, :string)
      belongs_to(:author, Author)
      has_many(:comments, DoubleDown.Repo.PreloadTest.Comment)
    end
  end

  defmodule Comment do
    use Ecto.Schema

    schema "comments" do
      field(:body, :string)
      belongs_to(:post, Post)
      belongs_to(:author, Author)
    end
  end

  defmodule Profile do
    use Ecto.Schema

    schema "profiles" do
      field(:bio, :string)
      belongs_to(:author, Author)
    end
  end

  defmodule Tag do
    use Ecto.Schema

    schema "tags" do
      field(:name, :string)
    end
  end

  defmodule PostTag do
    use Ecto.Schema

    schema "posts_tags" do
      belongs_to(:post, Post)
      belongs_to(:tag, Tag)
    end
  end

  # -------------------------------------------------------------------
  # has_many
  # -------------------------------------------------------------------

  describe "preload has_many" do
    setup do
      DoubleDown.Double.fallback(Repo, InMemory, [
        %Author{id: 1, name: "Alice"},
        %Post{id: 1, title: "First", author_id: 1},
        %Post{id: 2, title: "Second", author_id: 1},
        %Post{id: 3, title: "Other", author_id: 2}
      ])

      :ok
    end

    test "loads associated records" do
      author = DoubleDown.Test.Repo.get!(Author, 1)
      author = DoubleDown.Test.Repo.preload(author, :posts)
      assert length(author.posts) == 2
      assert Enum.map(author.posts, & &1.title) |> Enum.sort() == ["First", "Second"]
    end

    test "returns empty list when no matches" do
      author = %Author{id: 99, name: "Nobody"}
      author = DoubleDown.Test.Repo.preload(author, :posts)
      assert author.posts == []
    end
  end

  # -------------------------------------------------------------------
  # has_one
  # -------------------------------------------------------------------

  describe "preload has_one" do
    setup do
      DoubleDown.Double.fallback(Repo, InMemory, [
        %Author{id: 1, name: "Alice"},
        %Profile{id: 1, bio: "Hello", author_id: 1}
      ])

      :ok
    end

    test "loads single associated record" do
      author = DoubleDown.Test.Repo.get!(Author, 1)
      author = DoubleDown.Test.Repo.preload(author, :profile)
      assert author.profile.bio == "Hello"
    end

    test "returns nil when no match" do
      author = %Author{id: 99, name: "Nobody"}
      author = DoubleDown.Test.Repo.preload(author, :profile)
      assert author.profile == nil
    end
  end

  # -------------------------------------------------------------------
  # belongs_to
  # -------------------------------------------------------------------

  describe "preload belongs_to" do
    setup do
      DoubleDown.Double.fallback(Repo, InMemory, [
        %Author{id: 1, name: "Alice"},
        %Post{id: 1, title: "First", author_id: 1}
      ])

      :ok
    end

    test "loads parent record" do
      post = DoubleDown.Test.Repo.get!(Post, 1)
      post = DoubleDown.Test.Repo.preload(post, :author)
      assert post.author.name == "Alice"
    end

    test "returns nil when FK is nil" do
      post = %Post{id: 99, title: "Orphan", author_id: nil}
      post = DoubleDown.Test.Repo.preload(post, :author)
      assert post.author == nil
    end
  end

  # -------------------------------------------------------------------
  # Nested preloads
  # -------------------------------------------------------------------

  describe "nested preloads" do
    setup do
      DoubleDown.Double.fallback(Repo, InMemory, [
        %Author{id: 1, name: "Alice"},
        %Post{id: 1, title: "First", author_id: 1},
        %Comment{id: 1, body: "Great!", post_id: 1, author_id: 1},
        %Comment{id: 2, body: "Thanks!", post_id: 1, author_id: 1}
      ])

      :ok
    end

    test "preloads nested associations" do
      author = DoubleDown.Test.Repo.get!(Author, 1)
      author = DoubleDown.Test.Repo.preload(author, posts: :comments)

      assert length(author.posts) == 1
      post = hd(author.posts)
      assert length(post.comments) == 2
    end

    test "preloads multiple levels" do
      author = DoubleDown.Test.Repo.get!(Author, 1)
      author = DoubleDown.Test.Repo.preload(author, posts: [comments: :author])

      comment = author.posts |> hd() |> Map.get(:comments) |> hd()
      assert comment.author.name == "Alice"
    end
  end

  # -------------------------------------------------------------------
  # List of structs
  # -------------------------------------------------------------------

  describe "preload list of structs" do
    setup do
      DoubleDown.Double.fallback(Repo, InMemory, [
        %Author{id: 1, name: "Alice"},
        %Author{id: 2, name: "Bob"},
        %Post{id: 1, title: "Alice's Post", author_id: 1},
        %Post{id: 2, title: "Bob's Post", author_id: 2}
      ])

      :ok
    end

    test "preloads each struct in a list" do
      authors = DoubleDown.Test.Repo.all(Author)
      authors = DoubleDown.Test.Repo.preload(authors, :posts)

      assert Enum.all?(authors, fn a -> is_list(a.posts) end)
    end
  end

  # -------------------------------------------------------------------
  # nil and empty
  # -------------------------------------------------------------------

  describe "preload nil and empty" do
    setup do
      DoubleDown.Double.fallback(Repo, InMemory)
      :ok
    end

    test "preload nil returns nil" do
      assert DoubleDown.Test.Repo.preload(nil, :posts) == nil
    end

    test "preload empty list returns empty list" do
      assert DoubleDown.Test.Repo.preload([], :posts) == []
    end
  end

  # -------------------------------------------------------------------
  # Multiple preloads at once
  # -------------------------------------------------------------------

  describe "multiple preloads" do
    setup do
      DoubleDown.Double.fallback(Repo, InMemory, [
        %Author{id: 1, name: "Alice"},
        %Post{id: 1, title: "Post", author_id: 1},
        %Profile{id: 1, bio: "Bio", author_id: 1}
      ])

      :ok
    end

    test "preloads multiple associations" do
      author = DoubleDown.Test.Repo.get!(Author, 1)
      author = DoubleDown.Test.Repo.preload(author, [:posts, :profile])

      assert length(author.posts) == 1
      assert author.profile.bio == "Bio"
    end
  end

  # -------------------------------------------------------------------
  # opts variant
  # -------------------------------------------------------------------

  describe "preload with opts" do
    setup do
      DoubleDown.Double.fallback(Repo, InMemory, [
        %Author{id: 1, name: "Alice"},
        %Post{id: 1, title: "Post", author_id: 1}
      ])

      :ok
    end

    test "accepts opts (ignores them)" do
      author = DoubleDown.Test.Repo.get!(Author, 1)
      author = DoubleDown.Test.Repo.preload(author, :posts, force: true)
      assert length(author.posts) == 1
    end
  end
end
