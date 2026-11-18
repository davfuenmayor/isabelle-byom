package isabelle.byom
import isabelle._
import scala.language.unsafeNulls
import java.nio.file.{Files, Path => JPath}
import scala.concurrent.{Await, ExecutionContext, Future}
import scala.concurrent.duration._

object FileTests {
  def main(args: Array[String]): Unit = {
    given ExecutionContext = ExecutionContext.global
    val root = Files.createTempDirectory("byom-files-test-")
    def rejected(body: => Any): Unit = {
      var failed = false
      try { body } catch { case _: java.io.IOException | _: java.nio.file.InvalidPathException => failed = true; case ERROR(_) => failed = true }
      assert(failed, "Expected placement error")
    }
    try {
      for (path <- List("", ".", "..", "../escape", "/absolute", "a/../../escape", "bad\u0000path"))
        rejected(Files_Command.write(root, path, "no"))
      rejected(Files_Command.write(root, "large", "x" * (8 * 1024 * 1024 + 1)))
      val outside = Files.createTempDirectory("byom-outside-")
      try {
        Files.createSymbolicLink(root.resolve("link"), outside)
        rejected(Files_Command.write(root, "link/escape", "no"))
        assert(!Files.exists(outside.resolve("escape")))
      } finally { Files.delete(outside) }
      Files.writeString(root.resolve("blocked"), "not a directory")
      rejected(Files_Command.write(root, "blocked/child", "no"))
      Files.createDirectory(root.resolve("directory"))
      rejected(Files_Command.write(root, "directory", "no"))
      val readonly = Files.createDirectory(root.resolve("readonly"))
      val mode = Files.getPosixFilePermissions(readonly)
      try {
        Files.setPosixFilePermissions(readonly, java.nio.file.attribute.PosixFilePermissions.fromString("r-x------"))
        if (!Files.isWritable(readonly)) rejected(Files_Command.write(readonly, "denied", "no"))
        else println("Permission-denial check requires an unprivileged test user.")
      } finally Files.setPosixFilePermissions(readonly, mode)
      val writes = (1 to 50).map(n => Future(Files_Command.write(root, "nested/shared", "λ" * n)))
      Await.result(Future.sequence(writes), 30.seconds)
      assert(Files.readString(root.resolve("nested/shared")).forall(_ == 'λ'))
      // Native stop deletes a session root concurrently. Writers may finish or
      // return a filesystem error; they must never recreate that root.
      val stopped = Files.createDirectory(root.resolve("stopped"))
      val racing = (1 to 100).map(_ => Future {
        try { Files_Command.write(stopped, "nested/theory", "text") }
        catch { case _: java.io.IOException => () }
      })
      Isabelle_System.rm_tree(Path.explode(stopped.toString))
      Await.result(Future.sequence(racing), 30.seconds)
      assert(!Files.exists(stopped))
      rejected(Files_Command.write(stopped, "after-stop", "no"))
      val stream = Files.walk(root)
      try { assert(!stream.anyMatch(p => p.getFileName.toString.startsWith(".byom-"))) }
      finally stream.close()
      println("Path errors, atomic writes, concurrent parent creation and stop/write race passed.")
    } finally { Isabelle_System.rm_tree(Path.explode(root.toString)) }
  }
}
