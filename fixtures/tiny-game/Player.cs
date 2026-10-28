using UnityEngine;

public class Player : MonoBehaviour
{
    public float speed = 5f;
    private int health = 100;

    void Update()
    {
        var move = new Vector3(Input.GetAxis("Horizontal"), 0f, 0f);
        transform.position += move * speed * Time.deltaTime;
        Debug.Log("moving");
    }

    public void Hit(int damage)
    {
        health -= damage;
        if (health <= 0) { Debug.Log("dead"); Destroy(gameObject); }
    }
}
