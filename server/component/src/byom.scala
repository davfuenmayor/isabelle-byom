package isabelle.byom

import isabelle._
import scala.language.unsafeNulls
import java.nio.file.{Files, LinkOption, StandardCopyOption}

object Files_Command {
  private val nofollow = LinkOption.NOFOLLOW_LINKS
  private val projects = scala.collection.mutable.Map.empty[String, java.nio.file.Path]

  private def required(json: JSON.T, key: String): String =
    JSON.string(json, key).getOrElse(error("Missing string: " + key))

  private[byom] def write(root: java.nio.file.Path, name: String, text: String): JSON.T = {
    val relative = java.nio.file.Path.of(name)
    if (name.isEmpty || relative.isAbsolute || name.split("/", -1).contains(".."))
      error("Expected a relative path without '..'")
    if (Bytes(text).size > 8 * 1024 * 1024) error("File exceeds 8 MiB")
    val base = root.toRealPath()
    val target = base.resolve(relative).normalize()
    if (target == base || !target.startsWith(base)) error("Invalid file path")
    var parent = base
    val parts = base.relativize(target).iterator()
    while (parts.hasNext) {
      parent = parent.resolve(parts.next())
      if (Files.isSymbolicLink(parent)) error("Symbolic links are not allowed")
      if (parent != target && !Files.exists(parent, nofollow)) {
        try { Files.createDirectory(parent) }
        catch { case _: java.nio.file.FileAlreadyExistsException => () }
        if (Files.isSymbolicLink(parent) || !Files.isDirectory(parent, nofollow))
          error("Expected a directory without symbolic links")
      }
    }
    val temp = Files.createTempFile(target.getParent, ".byom-", ".tmp")
    try {
      Files.writeString(temp, text)
      Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }
    finally Files.deleteIfExists(temp)
    JSON.Object("path" -> target.toString)
  }

  private def placement[A](body: => A): A =
    try { body }
    catch {
      case ex: java.io.IOException => error("File placement failed: " + ex.getMessage)
      case ex: java.nio.file.InvalidPathException => error("Invalid file path: " + ex.getReason)
      case ex: SecurityException => error("File permission denied: " + ex.getMessage)
    }

  object Session_Write extends Server.Command("byom_write_file") {
    override val command_body: Server.Command_Body = { case (context, json: Map[_, _]) =>
      val id = JSON.uuid(json, "session_id").getOrElse(error("Missing session_id"))
      val session = context.server.the_session(id)
      placement { write(java.nio.file.Path.of(session.tmp_dir_name), required(json, "path"), required(json, "text")) }
    }
  }

  // Explicit project ownership: the caller releases it after all builds/sessions using it stop.
  object Project_Create extends Server.Command("byom_create_project") {
    override val command_body: Server.Command_Body = { case (_, ()) => projects.synchronized {
      val id = UUID.random_string()
      val root = placement { Files.createTempDirectory("byom-project-") }
      projects(id) = root
      JSON.Object("project_id" -> id, "dir" -> root.toString)
    }}
  }
  object Project_Write extends Server.Command("byom_write_project_file") {
    override val command_body: Server.Command_Body = { case (_, json: Map[_, _]) => projects.synchronized {
      val root = projects.getOrElse(required(json, "project_id"), error("Unknown project"))
      placement { write(root, required(json, "path"), required(json, "text")) }
    }}
  }
  object Project_Remove extends Server.Command("byom_remove_project") {
    override val command_body: Server.Command_Body = { case (_, json: Map[_, _]) => projects.synchronized {
      val id = required(json, "project_id")
      val root = projects.getOrElse(id, error("Unknown project"))
      placement { Isabelle_System.rm_tree(Path.explode(root.toString)) }
      projects.remove(id)
      JSON.Object("removed" -> id)
    }}
  }
}
class Commands extends Server.Commands(Files_Command.Session_Write,
  Files_Command.Project_Create, Files_Command.Project_Write, Files_Command.Project_Remove)
